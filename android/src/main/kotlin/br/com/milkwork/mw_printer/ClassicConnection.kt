package br.com.milkwork.mw_printer

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Conexão Bluetooth Clássico (SPP/RFCOMM).
 *
 * Tenta 3 estratégias de socket, pois cada fabricante (Samsung, Xiaomi,
 * Motorola...) se comporta de um jeito:
 *  1. Seguro via SDP (padrão)
 *  2. Inseguro via SDP
 *  3. Canal RFCOMM 1 via reflexão (resolve muitos Samsung/Xiaomi antigos)
 */
@SuppressLint("MissingPermission")
class ClassicConnection(
    private val adapter: BluetoothAdapter?,
    private val log: (String) -> Unit,
) {
    @Volatile private var socket: BluetoothSocket? = null
    @Volatile private var out: OutputStream? = null
    @Volatile var deviceId: String? = null
        private set

    /** Marcado pelo receiver de ACL_DISCONNECTED. */
    @Volatile var aclConnected: Boolean = false

    private val watchdog = Executors.newSingleThreadScheduledExecutor()

    val isConnected: Boolean
        get() {
            val s = socket ?: return false
            return try { s.isConnected && aclConnected } catch (_: Throwable) { false }
        }

    fun connect(device: BluetoothDevice, timeoutMs: Long): String {
        close()
        try { adapter?.cancelDiscovery() } catch (_: Throwable) {}

        val strategies: List<Pair<String, () -> BluetoothSocket>> = listOf(
            "secure" to { device.createRfcommSocketToServiceRecord(PrinterProfiles.SPP_UUID) },
            "insecure" to { device.createInsecureRfcommSocketToServiceRecord(PrinterProfiles.SPP_UUID) },
            "channel1" to {
                val m = device.javaClass.getMethod("createRfcommSocket", Int::class.javaPrimitiveType)
                m.invoke(device, 1) as BluetoothSocket
            },
        )

        val perAttempt = (timeoutMs / 2).coerceIn(4000L, 10000L)
        var lastError = ""
        for ((round, wait) in listOf(0L, 600L).withIndex()) {
            for ((name, factory) in strategies) {
                if (wait > 0) Thread.sleep(wait)
                var s: BluetoothSocket? = null
                try {
                    log("classic: conectando ${device.address} via $name (rodada ${round + 1})")
                    s = factory()
                    val sock = s
                    // connect() é bloqueante e não tem timeout: o watchdog fecha o socket.
                    val timer = watchdog.schedule({
                        try { sock.close() } catch (_: Throwable) {}
                    }, perAttempt, TimeUnit.MILLISECONDS)
                    sock.connect()
                    timer.cancel(false)
                    socket = sock
                    out = sock.outputStream
                    deviceId = device.address
                    aclConnected = true
                    log("classic: conectado via $name")
                    // Algumas impressoras perdem os primeiros bytes logo após conectar.
                    Thread.sleep(250)
                    return "OK"
                } catch (e: Throwable) {
                    lastError = "$name: ${e.javaClass.simpleName} ${e.message}"
                    log("classic: falhou $lastError")
                    try { s?.close() } catch (_: Throwable) {}
                }
            }
        }
        return "CONNECT_FAIL|$lastError"
    }

    /** Envia os bytes em blocos. Retorna "OK" ou "WRITE_FAIL|detalhe". */
    fun write(data: ByteArray, chunkSize: Int = 512, delayMs: Long = 8): String {
        val o = out ?: return "NOT_CONNECTED|sem socket"
        return try {
            var i = 0
            while (i < data.size) {
                val end = minOf(i + chunkSize, data.size)
                o.write(data, i, end - i)
                o.flush()
                i = end
                if (delayMs > 0 && i < data.size) Thread.sleep(delayMs)
            }
            // Dá tempo do buffer do rádio esvaziar antes de qualquer close().
            Thread.sleep((data.size / 40L).coerceIn(150L, 1500L))
            "OK"
        } catch (e: IOException) {
            aclConnected = false
            "WRITE_FAIL|${e.message}"
        } catch (e: Throwable) {
            "WRITE_FAIL|${e.javaClass.simpleName} ${e.message}"
        }
    }

    fun close() {
        try { out?.flush() } catch (_: Throwable) {}
        try { out?.close() } catch (_: Throwable) {}
        try { socket?.close() } catch (_: Throwable) {}
        out = null
        socket = null
        deviceId = null
        aclConnected = false
    }
}
