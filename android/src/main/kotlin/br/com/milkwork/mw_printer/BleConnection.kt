package br.com.milkwork.mw_printer

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Conexão BLE (GATT) com os cuidados necessários para Samsung e afins:
 *  - connectGatt na thread principal, autoConnect=false, TRANSPORT_LE
 *  - status 133/8/22/62: limpa cache (refresh), fecha e tenta de novo
 *  - MTU pedido uma única vez; se o aparelho derrubar a conexão, reconecta sem MTU
 *  - escolhe a característica pela lista de perfis conhecidos de impressora
 *  - escrita com controle de fluxo (aguarda onCharacteristicWrite a cada bloco)
 */
@SuppressLint("MissingPermission")
class BleConnection(
    private val context: Context,
    private val log: (String) -> Unit,
) {
    private sealed class Ev {
        data class State(val status: Int, val newState: Int) : Ev()
        data class Services(val status: Int) : Ev()
        data class Mtu(val mtu: Int, val status: Int) : Ev()
        data class Write(val status: Int) : Ev()
    }

    private val main = Handler(Looper.getMainLooper())
    private val events = LinkedBlockingQueue<Ev>()

    @Volatile private var gatt: BluetoothGatt? = null
    @Volatile private var writeChar: BluetoothGattCharacteristic? = null
    @Volatile private var connected = false
    @Volatile private var mtu = 23
    @Volatile var deviceId: String? = null
        private set

    /** Aparelhos onde o requestMtu derrubou a conexão (não pedir de novo). */
    private val skipMtu = HashSet<String>()

    val isConnected: Boolean get() = connected && gatt != null && writeChar != null

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) connected = false
            events.offer(Ev.State(status, newState))
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            events.offer(Ev.Services(status))
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            events.offer(Ev.Mtu(mtu, status))
        }

        override fun onCharacteristicWrite(
            g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int,
        ) {
            events.offer(Ev.Write(status))
        }
    }

    /** Espera um evento do tipo [T]. Retorna null em timeout ou desconexão. */
    private inline fun <reified T : Ev> await(timeoutMs: Long): T? {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (true) {
            val left = deadline - System.currentTimeMillis()
            if (left <= 0) return null
            val ev = events.poll(left, TimeUnit.MILLISECONDS) ?: return null
            if (ev is T) return ev
            if (ev is Ev.State && ev.newState == BluetoothProfile.STATE_DISCONNECTED && T::class != Ev.State::class) {
                return null
            }
        }
    }

    fun connect(device: BluetoothDevice, timeoutMs: Long): String {
        close()
        var lastError = ""
        for (attempt in 1..3) {
            val r = tryConnectOnce(device, timeoutMs, attempt)
            if (r == "OK") return r
            lastError = r
            if (r.startsWith("NO_WRITE_CHANNEL")) return r
            close()
            Thread.sleep(500L * attempt)
        }
        return if (lastError.startsWith("CONNECT_FAIL")) lastError else "CONNECT_FAIL|$lastError"
    }

    private fun tryConnectOnce(device: BluetoothDevice, timeoutMs: Long, attempt: Int): String {
        events.clear()
        log("ble: conectando ${device.address} (tentativa $attempt)")
        val latch = java.util.concurrent.CountDownLatch(1)
        main.post {
            gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
            } else {
                device.connectGatt(context, false, callback)
            }
            latch.countDown()
        }
        latch.await(3, TimeUnit.SECONDS)
        val g = gatt ?: return "CONNECT_FAIL|connectGatt null"

        val st = await<Ev.State>(timeoutMs)
        if (st == null || st.newState != BluetoothProfile.STATE_CONNECTED || st.status != BluetoothGatt.GATT_SUCCESS) {
            val code = st?.status ?: -1
            log("ble: falha na conexão status=$code")
            refresh(g)
            return "CONNECT_FAIL|gatt status=$code"
        }
        connected = true

        // Samsung: dar um respiro antes de operações GATT logo após conectar.
        Thread.sleep(if (attempt == 1) 350 else 600)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try { g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH) } catch (_: Throwable) {}
        }

        // Descoberta de serviços (com uma nova tentativa após limpar cache).
        var services = discover(g)
        if (services == null) return "CONNECT_FAIL|desconectou na descoberta"
        if (services.isEmpty()) {
            log("ble: nenhum serviço, limpando cache e tentando de novo")
            refresh(g)
            Thread.sleep(400)
            services = discover(g) ?: return "CONNECT_FAIL|desconectou na descoberta (2)"
        }

        val ch = pickWriteCharacteristic(g)
            ?: return "NO_WRITE_CHANNEL|serviços=${g.services.map { it.uuid }}"
        writeChar = ch
        log("ble: canal de escrita ${ch.service.uuid} / ${ch.uuid}")

        // MTU: depois de escolher o canal. Se derrubar, marca o aparelho e reconecta sem MTU.
        mtu = 23
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP && !skipMtu.contains(device.address)) {
            try {
                if (g.requestMtu(247)) {
                    val m = await<Ev.Mtu>(3000)
                    if (m != null && m.status == BluetoothGatt.GATT_SUCCESS) mtu = m.mtu
                }
            } catch (_: Throwable) {}
            if (!connected) {
                log("ble: aparelho desconectou após requestMtu; próximo sem MTU")
                skipMtu.add(device.address)
                return "CONNECT_FAIL|desconectou após MTU"
            }
        }
        log("ble: conectado mtu=$mtu")
        deviceId = device.address
        return "OK"
    }

    private fun discover(g: BluetoothGatt): List<*>? {
        events.clear()
        if (!g.discoverServices()) return emptyList<Any>()
        val ev = await<Ev.Services>(10000) ?: return null
        if (ev.status != BluetoothGatt.GATT_SUCCESS) return emptyList<Any>()
        return g.services
    }

    private fun pickWriteCharacteristic(g: BluetoothGatt): BluetoothGattCharacteristic? {
        fun writable(c: BluetoothGattCharacteristic): Boolean =
            c.properties and (BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0

        for ((svc, chr) in PrinterProfiles.BLE_WRITE_PROFILES) {
            val c = g.getService(svc)?.getCharacteristic(chr)
            if (c != null && writable(c)) return c
        }
        // Qualquer característica gravável em serviço conhecido de impressora.
        for (s in g.services) {
            if (s.uuid in PrinterProfiles.KNOWN_PRINTER_SERVICES) {
                s.characteristics.firstOrNull { writable(it) }?.let { return it }
            }
        }
        // Fallback: primeira gravável fora dos serviços padrão (preferindo sem resposta).
        val candidates = g.services
            .filter { it.uuid !in PrinterProfiles.IGNORED_SERVICES }
            .flatMap { it.characteristics }
            .filter { writable(it) }
        return candidates.firstOrNull {
            it.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0
        } ?: candidates.firstOrNull()
    }

    /** Escreve com controle de fluxo. Retorna "OK" ou "WRITE_FAIL|...". */
    @Suppress("DEPRECATION")
    fun write(data: ByteArray, delayMs: Long = 4): String {
        val g = gatt ?: return "NOT_CONNECTED|sem gatt"
        val c = writeChar ?: return "NOT_CONNECTED|sem canal"
        if (!connected) return "NOT_CONNECTED|desconectado"

        val noResp = c.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0
        val type = if (noResp) BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        // Muitas impressoras baratas têm buffer interno pequeno: limitar o bloco.
        val chunk = (mtu - 3).coerceIn(20, 180)

        var i = 0
        while (i < data.size) {
            if (!connected) return "WRITE_FAIL|desconectou no meio da impressão"
            val end = minOf(i + chunk, data.size)
            val part = data.copyOfRange(i, end)
            events.clear()

            var sent = false
            for (retry in 0 until 60) {
                sent = try {
                    if (Build.VERSION.SDK_INT >= 33) {
                        g.writeCharacteristic(c, part, type) == 0 // BluetoothStatusCodes.SUCCESS
                    } else {
                        c.writeType = type
                        c.value = part
                        g.writeCharacteristic(c)
                    }
                } catch (_: Throwable) { false }
                if (sent) break
                Thread.sleep(15) // pilha ocupada, aguarda
            }
            if (!sent) return "WRITE_FAIL|pilha BLE ocupada"

            val ev = await<Ev.Write>(if (noResp) 1500 else 4000)
            if (ev == null) {
                if (!connected) return "WRITE_FAIL|desconectou"
                // Alguns aparelhos antigos não confirmam WRITE_NO_RESPONSE: segue com pausa.
                if (!noResp) return "WRITE_FAIL|sem confirmação"
                Thread.sleep(20)
            } else if (ev.status != BluetoothGatt.GATT_SUCCESS) {
                return "WRITE_FAIL|status=${ev.status}"
            }
            i = end
            if (delayMs > 0) Thread.sleep(delayMs)
        }
        Thread.sleep(200)
        return "OK"
    }

    private fun refresh(g: BluetoothGatt) {
        try {
            val m = g.javaClass.getMethod("refresh")
            m.invoke(g)
        } catch (_: Throwable) {}
    }

    fun close() {
        val g = gatt
        gatt = null
        writeChar = null
        connected = false
        deviceId = null
        if (g != null) {
            try { g.disconnect() } catch (_: Throwable) {}
            // Samsung: fechar logo após disconnect pode deixar o rádio preso.
            Thread.sleep(250)
            try { g.close() } catch (_: Throwable) {}
        }
        events.clear()
    }
}
