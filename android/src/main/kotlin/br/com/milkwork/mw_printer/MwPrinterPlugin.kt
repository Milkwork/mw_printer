package br.com.milkwork.mw_printer

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

@SuppressLint("MissingPermission")
class MwPrinterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener, PluginRegistry.ActivityResultListener {

    companion object {
        private const val TAG = "mw_printer"
        private const val REQ_PERMS = 47101
        private const val REQ_ENABLE = 47102
        private const val PREFS = "mw_printer_prefs"
        private val DEFAULT_PINS = listOf("0000", "1234", "1111", "8888")
    }

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var prefs: SharedPreferences
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null

    private val main = Handler(Looper.getMainLooper())
    /** Todas as operações Bluetooth rodam em série nesta thread. */
    private val worker = Executors.newSingleThreadExecutor()

    private var adapter: BluetoothAdapter? = null
    private lateinit var classic: ClassicConnection
    private lateinit var ble: BleConnection

    /** Transporte da conexão ativa: "classic" | "ble" | null. */
    @Volatile private var active: String? = null

    @Volatile private var permLatch: CountDownLatch? = null
    @Volatile private var enableLatch: CountDownLatch? = null
    private var aclReceiverRegistered = false

    // -------------------------------------------------------------------------
    // Ciclo de vida
    // -------------------------------------------------------------------------

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        context = b.applicationContext
        prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        channel = MethodChannel(b.binaryMessenger, "br.com.milkwork/mw_printer")
        channel.setMethodCallHandler(this)
        val mgr = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        adapter = mgr?.adapter
        classic = ClassicConnection(adapter, ::log)
        ble = BleConnection(context, ::log)
        registerAclReceiver()
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        try { if (aclReceiverRegistered) context.unregisterReceiver(aclReceiver) } catch (_: Throwable) {}
        aclReceiverRegistered = false
        worker.execute {
            try { classic.close() } catch (_: Throwable) {}
            try { ble.close() } catch (_: Throwable) {}
        }
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        activity = b.activity
        binding = b
        b.addRequestPermissionsResultListener(this)
        b.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        binding?.removeRequestPermissionsResultListener(this)
        binding?.removeActivityResultListener(this)
        binding = null
        activity = null
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = onAttachedToActivity(b)

    // -------------------------------------------------------------------------
    // Util
    // -------------------------------------------------------------------------

    private fun log(msg: String) {
        Log.d(TAG, msg)
        main.post { try { channel.invokeMethod("log", msg) } catch (_: Throwable) {} }
    }

    private fun status(code: String, detail: String = "", transport: String? = null): Map<String, Any?> =
        mapOf("code" to code, "detail" to detail, "transport" to transport)

    /** Converte "CODE|detalhe" em mapa de status. */
    private fun statusOf(r: String, transport: String? = null): Map<String, Any?> {
        val i = r.indexOf('|')
        return if (i < 0) status(r, "", transport) else status(r.substring(0, i), r.substring(i + 1), transport)
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            val r: Any? = try { block() } catch (e: Throwable) {
                log("erro: ${e.javaClass.simpleName} ${e.message}")
                status("UNKNOWN", "${e.javaClass.simpleName}: ${e.message}")
            }
            main.post { result.success(r) }
        }
    }

    private fun has(p: String) = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    /** O app declarou BLUETOOTH_SCAN com neverForLocation? */
    private fun scanNeverForLocation(): Boolean {
        if (Build.VERSION.SDK_INT < 31) return false
        return try {
            val pi: PackageInfo = if (Build.VERSION.SDK_INT >= 33) {
                context.packageManager.getPackageInfo(context.packageName,
                    PackageManager.PackageInfoFlags.of(PackageManager.GET_PERMISSIONS.toLong()))
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
            }
            val names = pi.requestedPermissions ?: return false
            val flags = pi.requestedPermissionsFlags ?: return false
            val idx = names.indexOf(Manifest.permission.BLUETOOTH_SCAN)
            // PackageInfo.REQUESTED_PERMISSION_NEVER_FOR_LOCATION = 0x00010000
            idx >= 0 && (flags[idx] and 0x00010000) != 0
        } catch (_: Throwable) { false }
    }

    /** Localização é exigida para busca no Android <= 11, ou 12+ sem neverForLocation. */
    private fun locationRequiredForScan() = Build.VERSION.SDK_INT < 31 || !scanNeverForLocation()

    private fun requiredPermissions(forScan: Boolean): List<String> {
        val list = ArrayList<String>()
        if (Build.VERSION.SDK_INT >= 31) {
            list += Manifest.permission.BLUETOOTH_CONNECT
            if (forScan) list += Manifest.permission.BLUETOOTH_SCAN
        }
        if (forScan && locationRequiredForScan()) list += Manifest.permission.ACCESS_FINE_LOCATION
        return list
    }

    private fun isLocationOn(): Boolean {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return true
        return try {
            if (Build.VERSION.SDK_INT >= 28) lm.isLocationEnabled
            else lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        } catch (_: Throwable) { true }
    }

    /** Pede permissões e espera a resposta (chamar fora da main thread). */
    private fun requestPermissionsBlocking(perms: List<String>): Boolean {
        val act = activity ?: return false
        val latch = CountDownLatch(1)
        permLatch = latch
        main.post {
            try { act.requestPermissions(perms.toTypedArray(), REQ_PERMS) }
            catch (e: Throwable) { log("requestPermissions: ${e.message}"); latch.countDown() }
        }
        latch.await(120, TimeUnit.SECONDS)
        permLatch = null
        return perms.all { has(it) }
    }

    override fun onRequestPermissionsResult(code: Int, perms: Array<out String>, results: IntArray): Boolean {
        if (code != REQ_PERMS) return false
        permLatch?.countDown()
        return true
    }

    override fun onActivityResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != REQ_ENABLE) return false
        enableLatch?.countDown()
        return true
    }

    private fun requestEnableBlocking(): Boolean {
        val a = adapter ?: return false
        if (a.isEnabled) return true
        val act = activity ?: return false
        if (Build.VERSION.SDK_INT >= 31 && !has(Manifest.permission.BLUETOOTH_CONNECT)) return false
        val latch = CountDownLatch(1)
        enableLatch = latch
        main.post {
            try {
                act.startActivityForResult(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), REQ_ENABLE)
            } catch (e: Throwable) {
                log("requestEnable: ${e.message}")
                latch.countDown()
            }
        }
        latch.await(60, TimeUnit.SECONDS)
        enableLatch = null
        // O adaptador leva um instante para ficar ON.
        repeat(30) { if (a.isEnabled) return true; Thread.sleep(150) }
        return a.isEnabled
    }

    private fun ensureReady(request: Boolean, forScan: Boolean): Map<String, Any?> {
        val a = adapter ?: return status("BT_UNSUPPORTED")
        val perms = requiredPermissions(forScan)
        if (perms.any { !has(it) }) {
            if (!request || activity == null) return status("NO_PERMISSION", perms.filter { !has(it) }.joinToString())
            if (!requestPermissionsBlocking(perms.filter { !has(it) })) {
                val act = activity
                val stillMissing = perms.filter { !has(it) }
                val permanent = act != null && stillMissing.any { !act.shouldShowRequestPermissionRationale(it) }
                return status(if (permanent) "PERMISSION_PERMANENTLY_DENIED" else "NO_PERMISSION", stillMissing.joinToString())
            }
        }
        if (!a.isEnabled) {
            if (!request || !requestEnableBlocking()) return status("BT_OFF")
        }
        if (forScan && locationRequiredForScan() && !isLocationOn()) return status("LOCATION_OFF")
        return status("OK")
    }

    private fun registerReceiverCompat(r: BroadcastReceiver, f: IntentFilter) {
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(r, f, Context.RECEIVER_EXPORTED)
        else context.registerReceiver(r, f)
    }

    @Suppress("DEPRECATION")
    private fun deviceFrom(i: Intent): BluetoothDevice? =
        if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        else i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)

    @Suppress("DEPRECATION")
    private fun classFrom(i: Intent): BluetoothClass? =
        if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(BluetoothDevice.EXTRA_CLASS, BluetoothClass::class.java)
        else i.getParcelableExtra(BluetoothDevice.EXTRA_CLASS)

    // -------------------------------------------------------------------------
    // Receiver ACL (detecta desconexão da impressora Clássica)
    // -------------------------------------------------------------------------

    private val aclReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            when (i.action) {
                BluetoothDevice.ACTION_ACL_DISCONNECTED -> {
                    val d = deviceFrom(i)
                    if (d != null && d.address == classic.deviceId) {
                        log("classic: ACL desconectado ${d.address}")
                        classic.aclConnected = false
                    }
                }
                BluetoothAdapter.ACTION_STATE_CHANGED -> {
                    val s = i.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)
                    if (s == BluetoothAdapter.STATE_OFF || s == BluetoothAdapter.STATE_TURNING_OFF) {
                        classic.aclConnected = false
                    }
                }
            }
        }
    }

    private fun registerAclReceiver() {
        try {
            val f = IntentFilter().apply {
                addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
                addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            }
            registerReceiverCompat(aclReceiver, f)
            aclReceiverRegistered = true
        } catch (e: Throwable) { log("acl receiver: ${e.message}") }
    }

    // -------------------------------------------------------------------------
    // Métodos
    // -------------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkReady" -> runAsync(result) {
                ensureReady(call.argument<Boolean>("request") ?: true, call.argument<Boolean>("forScan") ?: true)
            }
            "requestEnable" -> runAsync(result) {
                when {
                    adapter == null -> status("BT_UNSUPPORTED")
                    Build.VERSION.SDK_INT >= 31 && !has(Manifest.permission.BLUETOOTH_CONNECT) -> ensureReady(true, false)
                    else -> status(if (requestEnableBlocking()) "OK" else "BT_OFF")
                }
            }
            "openAppSettings" -> openSettings(result,
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)))
            "openLocationSettings" -> openSettings(result, Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
            "scan" -> runAsync(result) {
                scan(call.argument<Int>("seconds") ?: 8, call.argument<Boolean>("includeBonded") ?: true)
            }
            "bondedDevices" -> runAsync(result) { bonded() }
            "pair" -> runAsync(result) {
                pair(call.argument<String>("id") ?: "",
                    call.argument<List<String>>("pins") ?: DEFAULT_PINS,
                    (call.argument<Int>("timeoutMs") ?: 30000).toLong())
            }
            "unpair" -> runAsync(result) { unpair(call.argument<String>("id") ?: "") }
            "connect" -> runAsync(result) {
                connect(call.argument<String>("id") ?: "", call.argument<String>("transport") ?: "unknown",
                    (call.argument<Int>("timeoutMs") ?: 12000).toLong())
            }
            "isConnected" -> runAsync(result) { isConnected(call.argument<String>("id")) }
            "write" -> runAsync(result) { write(call.argument<ByteArray>("bytes") ?: ByteArray(0)) }
            "disconnect" -> runAsync(result) { disconnectAll(); status("OK") }
            else -> result.notImplemented()
        }
    }

    private fun openSettings(result: MethodChannel.Result, i: Intent) {
        try {
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(i)
            result.success(status("OK"))
        } catch (e: Throwable) { result.success(status("UNKNOWN", "${e.message}")) }
    }

    // -------------------------------------------------------------------------
    // Busca (Clássico + BLE simultâneos)
    // -------------------------------------------------------------------------

    private class Found(
        val id: String, var name: String, var transport: String, var bonded: Boolean,
        var rssi: Int, var isPrinter: Boolean,
    ) {
        fun toMap() = mapOf("id" to id, "name" to name, "transport" to transport,
            "bonded" to bonded, "rssi" to rssi, "isPrinter" to isPrinter)
    }

    private fun typeOf(d: BluetoothDevice, fallback: String): String = try {
        when (d.type) {
            BluetoothDevice.DEVICE_TYPE_CLASSIC -> "classic"
            BluetoothDevice.DEVICE_TYPE_LE -> "ble"
            BluetoothDevice.DEVICE_TYPE_DUAL -> "dual"
            else -> fallback
        }
    } catch (_: Throwable) { fallback }

    private fun mergeTransport(a: String, b: String): String =
        if (a == b) a else if (a == "unknown") b else if (b == "unknown") a else "dual"

    private fun bonded(): List<Map<String, Any?>> {
        val a = adapter ?: return emptyList()
        if (Build.VERSION.SDK_INT >= 31 && !has(Manifest.permission.BLUETOOTH_CONNECT)) return emptyList()
        return try {
            a.bondedDevices.orEmpty()
                .filter { !PrinterProfiles.classIsCertainlyNotPrinter(it.bluetoothClass) }
                .map { d ->
                    val name = d.name ?: ""
                    Found(d.address, name, typeOf(d, "classic"), true, 0,
                        PrinterProfiles.classLooksLikePrinter(d.bluetoothClass) || PrinterProfiles.nameLooksLikePrinter(name)
                    ).toMap()
                }
        } catch (_: Throwable) { emptyList() }
    }

    private fun scan(seconds: Int, includeBonded: Boolean): List<Map<String, Any?>> {
        val ready = ensureReady(true, true)
        if (ready["code"] != "OK") {
            log("scan: não pronto ${ready["code"]}")
            // Mesmo sem permissão de busca, devolve os pareados se possível.
            return if (includeBonded) bonded() else emptyList()
        }
        val a = adapter!!
        val found = ConcurrentHashMap<String, Found>()

        if (includeBonded) {
            for (m in bonded()) {
                val id = m["id"] as String
                found[id] = Found(id, m["name"] as String, m["transport"] as String, true, 0, m["isPrinter"] as Boolean)
            }
        }

        fun upsert(id: String, name: String, transport: String, bondedNow: Boolean, rssi: Int, isP: Boolean) {
            val f = found[id]
            if (f == null) {
                found[id] = Found(id, name, transport, bondedNow, rssi, isP)
            } else {
                if (f.name.isBlank()) f.name = name
                f.transport = mergeTransport(f.transport, transport)
                f.rssi = if (f.rssi == 0) rssi else maxOf(f.rssi, rssi)
                f.isPrinter = f.isPrinter || isP
                f.bonded = f.bonded || bondedNow
            }
        }

        // --- Clássico ---
        val classicReceiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                if (i.action != BluetoothDevice.ACTION_FOUND) return
                val d = deviceFrom(i) ?: return
                val cls = classFrom(i)
                if (PrinterProfiles.classIsCertainlyNotPrinter(cls)) return
                val name = i.getStringExtra(BluetoothDevice.EXTRA_NAME) ?: d.name ?: ""
                val rssi = i.getShortExtra(BluetoothDevice.EXTRA_RSSI, 0).toInt()
                val isP = PrinterProfiles.classLooksLikePrinter(cls) || PrinterProfiles.nameLooksLikePrinter(name)
                upsert(d.address, name, typeOf(d, "classic"), d.bondState == BluetoothDevice.BOND_BONDED, rssi, isP)
            }
        }

        // --- BLE ---
        val bleCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, r: ScanResult) = handle(r)
            override fun onBatchScanResults(results: MutableList<ScanResult>) { results.forEach { handle(it) } }
            override fun onScanFailed(errorCode: Int) { log("ble scan falhou: $errorCode") }

            fun handle(r: ScanResult) {
                val d = r.device
                val name = r.scanRecord?.deviceName ?: d.name ?: ""
                val uuids = r.scanRecord?.serviceUuids?.map { it.uuid }.orEmpty()
                val isP = uuids.any { it in PrinterProfiles.KNOWN_PRINTER_SERVICES } || PrinterProfiles.nameLooksLikePrinter(name)
                upsert(d.address, name, "ble", d.bondState == BluetoothDevice.BOND_BONDED, r.rssi, isP)
            }
        }

        var classicStarted = false
        var classicRegistered = false
        var bleStarted = false
        try {
            registerReceiverCompat(classicReceiver, IntentFilter(BluetoothDevice.ACTION_FOUND))
            classicRegistered = true
            try { a.cancelDiscovery() } catch (_: Throwable) {}
            classicStarted = a.startDiscovery()
            log("scan: clássico iniciado=$classicStarted")
        } catch (e: Throwable) { log("scan clássico: ${e.message}") }

        try {
            val scanner = a.bluetoothLeScanner
            if (scanner != null) {
                val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
                scanner.startScan(null, settings, bleCallback)
                bleStarted = true
            }
            log("scan: ble iniciado=$bleStarted")
        } catch (e: Throwable) { log("scan ble: ${e.message}") }

        Thread.sleep(seconds.coerceIn(2, 30) * 1000L)

        try { if (bleStarted) a.bluetoothLeScanner?.stopScan(bleCallback) } catch (_: Throwable) {}
        try { if (classicStarted) a.cancelDiscovery() } catch (_: Throwable) {}
        try { if (classicRegistered) context.unregisterReceiver(classicReceiver) } catch (_: Throwable) {}

        // Aparelhos dual mode que anunciam endereço BLE diferente do Clássico
        // (mesmo nome): mostra um só e guarda o endereço BLE como alternativa.
        val groups = found.values.filter { it.name.isNotBlank() }.groupBy { it.name }
        for ((_, group) in groups) {
            if (group.size != 2) continue
            val c = group.firstOrNull { it.transport == "classic" || it.transport == "dual" } ?: continue
            val b = group.firstOrNull { it.transport == "ble" && it !== c } ?: continue
            prefs.edit().putString("ble_alias_${c.id}", b.id).apply()
            c.transport = "dual"
            c.isPrinter = c.isPrinter || b.isPrinter
            found.remove(b.id)
        }
        log("scan: ${found.size} dispositivos")
        return found.values.map { it.toMap() }
    }

    // -------------------------------------------------------------------------
    // Pareamento dentro do app (PIN automático)
    // -------------------------------------------------------------------------

    private fun pair(id: String, pins: List<String>, timeoutMs: Long): Map<String, Any?> {
        val a = adapter ?: return status("BT_UNSUPPORTED")
        val ready = ensureReady(true, false)
        if (ready["code"] != "OK") return ready
        if (!BluetoothAdapter.checkBluetoothAddress(id)) return status("INVALID_ARGUMENT", "id inválido: $id")
        val d = a.getRemoteDevice(id)
        if (d.bondState == BluetoothDevice.BOND_BONDED) return status("OK", "já pareado")
        if (typeOf(d, "unknown") == "ble") return status("OK", "BLE não exige pareamento", "ble")
        return bondBlocking(d, pins, timeoutMs)
    }

    private fun bondBlocking(d: BluetoothDevice, pins: List<String>, timeoutMs: Long): Map<String, Any?> {
        try { adapter?.cancelDiscovery() } catch (_: Throwable) {}
        val pinList = pins.ifEmpty { DEFAULT_PINS }
        val pinIndex = AtomicInteger(0)
        val pinRequested = AtomicBoolean(false)
        val finalState = AtomicInteger(BluetoothDevice.BOND_NONE)

        for (attempt in pinList.indices) {
            pinIndex.set(attempt)
            val latch = CountDownLatch(1)
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(c: Context, i: Intent) {
                    val dev = deviceFrom(i) ?: return
                    if (dev.address != d.address) return
                    when (i.action) {
                        BluetoothDevice.ACTION_PAIRING_REQUEST -> {
                            val variant = i.getIntExtra(BluetoothDevice.EXTRA_PAIRING_VARIANT, -1)
                            log("pair: pedido de pareamento variante=$variant")
                            // 0 = PIN, 5 = PIN de 16 dígitos. Outras variantes (confirmação /
                            // consentimento): o sistema mostra "Parear?" por cima do app.
                            if (variant == BluetoothDevice.PAIRING_VARIANT_PIN || variant == 5) {
                                pinRequested.set(true)
                                val pin = pinList[pinIndex.get()]
                                try {
                                    val ok = dev.setPin(pin.toByteArray())
                                    log("pair: PIN $pin enviado=$ok")
                                    if (ok && isOrderedBroadcast) try { abortBroadcast() } catch (_: Throwable) {}
                                } catch (e: Throwable) { log("pair: setPin falhou ${e.message}") }
                            }
                        }
                        BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                            val s = i.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)
                            log("pair: estado=$s")
                            if (s == BluetoothDevice.BOND_BONDED || s == BluetoothDevice.BOND_NONE) {
                                finalState.set(s)
                                latch.countDown()
                            }
                        }
                    }
                }
            }
            val f = IntentFilter().apply {
                addAction(BluetoothDevice.ACTION_PAIRING_REQUEST)
                addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
                priority = IntentFilter.SYSTEM_HIGH_PRIORITY - 1
            }
            registerReceiverCompat(receiver, f)
            try {
                log("pair: createBond ${d.address} (PIN ${pinList[attempt]})")
                val started = d.createBond()
                if (!started && d.bondState != BluetoothDevice.BOND_BONDING) {
                    return if (d.bondState == BluetoothDevice.BOND_BONDED) status("OK")
                    else status("PAIR_FAIL", "createBond retornou false")
                }
                latch.await(timeoutMs, TimeUnit.MILLISECONDS)
            } finally {
                try { context.unregisterReceiver(receiver) } catch (_: Throwable) {}
            }
            if (d.bondState == BluetoothDevice.BOND_BONDED || finalState.get() == BluetoothDevice.BOND_BONDED) {
                log("pair: pareado")
                Thread.sleep(500) // Samsung: esperar estabilizar antes de conectar
                return status("OK")
            }
            if (!pinRequested.get()) {
                // Falhou sem pedir PIN: cancelado, impressora desligada ou fora de alcance.
                return status("PAIR_FAIL", "sem pedido de PIN (cancelado ou fora de alcance)")
            }
            log("pair: PIN ${pinList[attempt]} recusado, tentando o próximo")
            pinRequested.set(false)
            Thread.sleep(800)
        }
        return status("PAIR_FAIL", "nenhum PIN aceito")
    }

    private fun unpair(id: String): Map<String, Any?> {
        val a = adapter ?: return status("BT_UNSUPPORTED")
        if (!BluetoothAdapter.checkBluetoothAddress(id)) return status("INVALID_ARGUMENT")
        if (classic.deviceId == id || ble.deviceId == id) disconnectAll()
        return try {
            val d = a.getRemoteDevice(id)
            d.javaClass.getMethod("removeBond").invoke(d)
            prefs.edit().remove("t_$id").remove("ble_alias_$id").apply()
            status("OK")
        } catch (e: Throwable) { status("UNKNOWN", "${e.message}") }
    }

    // -------------------------------------------------------------------------
    // Conexão / escrita
    // -------------------------------------------------------------------------

    private fun isConnected(id: String?): Boolean = when (active) {
        "classic" -> classic.isConnected && (id == null || classic.deviceId == id)
        "ble" -> ble.isConnected && (id == null || ble.deviceId == id ||
                prefs.getString("ble_alias_$id", null) == ble.deviceId)
        else -> false
    }

    private fun disconnectAll() {
        try { classic.close() } catch (_: Throwable) {}
        try { ble.close() } catch (_: Throwable) {}
        active = null
    }

    private fun connect(id: String, transport: String, timeoutMs: Long): Map<String, Any?> {
        val a = adapter ?: return status("BT_UNSUPPORTED")
        if (!BluetoothAdapter.checkBluetoothAddress(id)) return status("INVALID_ARGUMENT", "id inválido: $id")
        val ready = ensureReady(true, false)
        if (ready["code"] != "OK") return ready
        if (isConnected(id)) return status("OK", "já conectado", active)

        val hadConnection = active != null
        disconnectAll()
        try { a.cancelDiscovery() } catch (_: Throwable) {}
        Thread.sleep(if (hadConnection) 1000 else 200) // Samsung: não reconectar imediatamente

        val d = a.getRemoteDevice(id)
        val devType = typeOf(d, "unknown")
        val remembered = prefs.getString("t_$id", null)
        val order: List<String> = when {
            transport == "ble" -> listOf("ble")
            transport == "classic" -> listOf("classic", "ble")
            remembered == "ble" -> listOf("ble", "classic")
            remembered == "classic" -> listOf("classic", "ble")
            devType == "ble" -> listOf("ble")
            devType == "classic" -> listOf("classic")
            else -> listOf("classic", "ble")
        }
        log("connect: $id tipo=$devType lembrado=$remembered ordem=$order")

        var last: Map<String, Any?> = status("CONNECT_FAIL")
        for ((idx, t) in order.withIndex()) {
            if (idx > 0) Thread.sleep(800)
            if (t == "classic") {
                if (d.bondState != BluetoothDevice.BOND_BONDED) {
                    val p = bondBlocking(d, DEFAULT_PINS, 30000)
                    if (p["code"] != "OK") { last = p; continue }
                }
                val r = classic.connect(d, timeoutMs)
                if (r == "OK") {
                    active = "classic"
                    prefs.edit().putString("t_$id", "classic").apply()
                    return status("OK", "", "classic")
                }
                last = statusOf(r, "classic")
                classic.close()
            } else {
                val bleId = prefs.getString("ble_alias_$id", null) ?: id
                val r = ble.connect(a.getRemoteDevice(bleId), timeoutMs)
                if (r == "OK") {
                    active = "ble"
                    prefs.edit().putString("t_$id", "ble").apply()
                    return status("OK", "", "ble")
                }
                last = statusOf(r, "ble")
                ble.close()
            }
        }
        return last
    }

    private fun write(bytes: ByteArray): Map<String, Any?> {
        if (bytes.isEmpty()) return status("OK")
        val t = active ?: return status("NOT_CONNECTED")
        val r = when (t) {
            "classic" -> if (classic.isConnected) classic.write(bytes) else "NOT_CONNECTED"
            else -> if (ble.isConnected) ble.write(bytes) else "NOT_CONNECTED"
        }
        log("write: ${bytes.size} bytes via $t -> $r")
        if (!r.startsWith("OK")) {
            // Derruba a conexão quebrada para a próxima tentativa reconectar do zero.
            disconnectAll()
        }
        return statusOf(r, t)
    }
}
