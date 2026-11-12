import CoreBluetooth
import Flutter
import UIKit

/// iOS: somente BLE (a Apple não libera Bluetooth Clássico/SPP sem certificação MFi).
public class MwPrinterPlugin: NSObject, FlutterPlugin, CBCentralManagerDelegate, CBPeripheralDelegate {

  private var channel: FlutterMethodChannel!
  private var central: CBCentralManager?
  /// Fila dos callbacks do CoreBluetooth.
  private let queue = DispatchQueue(label: "br.com.milkwork.mw_printer.ble")
  /// Operações serializadas (bloqueantes, fora da main thread).
  private let work = DispatchQueue(label: "br.com.milkwork.mw_printer.work")

  private var discovered: [UUID: (CBPeripheral, String, Int, Bool)] = [:]
  private var peripheral: CBPeripheral?
  private var writeChar: CBCharacteristic?

  // Sinais de eventos
  private var readySem: DispatchSemaphore?
  private var connectSem: DispatchSemaphore?
  private var connectError: String?
  private var servicesSem: DispatchSemaphore?
  private var charsPending = 0
  private var charsSem: DispatchSemaphore?
  private var writeSem: DispatchSemaphore?
  private var writeError: String?

  private static let writeProfiles: [(CBUUID, CBUUID)] = [
    (CBUUID(string: "18F0"), CBUUID(string: "2AF1")),
    (CBUUID(string: "FF00"), CBUUID(string: "FF02")),
    (CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455"), CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")),
    (CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"), CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F")),
    (CBUUID(string: "FFE0"), CBUUID(string: "FFE1")),
    (CBUUID(string: "FFF0"), CBUUID(string: "FFF2")),
    (CBUUID(string: "AE30"), CBUUID(string: "AE01")),
    (CBUUID(string: "AE00"), CBUUID(string: "AE01")),
    (CBUUID(string: "FEE7"), CBUUID(string: "FEC7")),
    (CBUUID(string: "FF00"), CBUUID(string: "FF01")),
  ]
  private static let knownServices: Set<CBUUID> = Set(writeProfiles.map { $0.0 })
  private static let ignoredServices: Set<CBUUID> = [
    CBUUID(string: "1800"), CBUUID(string: "1801"), CBUUID(string: "180A"), CBUUID(string: "180F"),
  ]
  private static let nameHints = [
    "knup", "kp-", "kp ", "kp1", "printer", "print", "pos", "mpt", "pt-", "pt2", "pt3", "mtp",
    "goojprt", "xprinter", "xp-", "rpp", "rongta", "hprt", "hm-", "zjiang", "zj-", "leopardo",
    "datecs", "dpp", "elgin", "bematech", "epson", "tm-", "sunmi", "spp", "thermal", "inner",
    "qs-", "p58", "p80", "58mm", "80mm", "jp-", "mht", "gp-", "gprinter", "iposprinter", "seypos",
    "sm-l", "woosim", "zebra", "cpcl", "m58", "m80", "ez-", "dl-", "pl58", "impressora",
  ]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = MwPrinterPlugin()
    instance.channel = FlutterMethodChannel(name: "br.com.milkwork/mw_printer", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: instance.channel)
  }

  // MARK: - Util

  private func log(_ msg: String) {
    NSLog("[mw_printer] %@", msg)
    DispatchQueue.main.async { self.channel.invokeMethod("log", arguments: msg) }
  }

  private func status(_ code: String, _ detail: String = "", _ transport: String? = nil) -> [String: Any?] {
    return ["code": code, "detail": detail, "transport": transport]
  }

  private func reply(_ result: @escaping FlutterResult, _ block: @escaping () -> Any?) {
    work.async {
      let r = block()
      DispatchQueue.main.async { result(r) }
    }
  }

  /// Cria o CBCentralManager (dispara o pedido de permissão) e espera um estado definido.
  private func ensureCentral(timeout: Double = 8) -> CBCentralManager {
    if central == nil {
      let sem = DispatchSemaphore(value: 0)
      readySem = sem
      central = CBCentralManager(delegate: self, queue: queue,
                                 options: [CBCentralManagerOptionShowPowerAlertKey: false])
      _ = sem.wait(timeout: .now() + timeout)
      readySem = nil
    } else if central!.state == .unknown || central!.state == .resetting {
      let sem = DispatchSemaphore(value: 0)
      readySem = sem
      _ = sem.wait(timeout: .now() + timeout)
      readySem = nil
    }
    return central!
  }

  private func readyStatus() -> [String: Any?] {
    let c = ensureCentral()
    if #available(iOS 13.1, *) {
      switch CBCentralManager.authorization {
      case .denied: return status("PERMISSION_PERMANENTLY_DENIED")
      case .restricted: return status("NO_PERMISSION", "restricted")
      default: break
      }
    }
    switch c.state {
    case .poweredOn: return status("OK")
    case .poweredOff: return status("BT_OFF")
    case .unauthorized: return status("PERMISSION_PERMANENTLY_DENIED")
    case .unsupported: return status("BT_UNSUPPORTED")
    default: return status("BT_OFF", "estado=\(c.state.rawValue)")
    }
  }

  private func looksLikePrinter(_ name: String, _ uuids: [CBUUID]) -> Bool {
    if uuids.contains(where: { MwPrinterPlugin.knownServices.contains($0) }) { return true }
    let n = name.lowercased()
    return MwPrinterPlugin.nameHints.contains { n.contains($0) }
  }

  // MARK: - Métodos

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "checkReady", "requestEnable":
      reply(result) { self.readyStatus() }
    case "openAppSettings":
      DispatchQueue.main.async {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        result(self.status("OK"))
      }
    case "openLocationSettings":
      result(status("OK"))
    case "scan":
      let seconds = args["seconds"] as? Int ?? 8
      reply(result) { self.scan(seconds: seconds) }
    case "bondedDevices":
      result([])
    case "pair":
      // BLE não exige pareamento explícito. Se a impressora exigir criptografia,
      // o próprio iOS mostra o diálogo de pareamento dentro do app.
      result(status("OK", "BLE não exige pareamento", "ble"))
    case "unpair":
      result(status("OK"))
    case "connect":
      let id = args["id"] as? String ?? ""
      let transport = args["transport"] as? String ?? "unknown"
      let timeoutMs = args["timeoutMs"] as? Int ?? 12000
      reply(result) { self.connect(id: id, transport: transport, timeout: Double(timeoutMs) / 1000) }
    case "isConnected":
      let id = args["id"] as? String
      reply(result) { self.isConnected(id) }
    case "write":
      let data = (args["bytes"] as? FlutterStandardTypedData)?.data ?? Data()
      reply(result) { self.write(data) }
    case "disconnect":
      reply(result) { self.disconnect(); return self.status("OK") }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Busca

  private func scan(seconds: Int) -> [[String: Any]] {
    let ready = readyStatus()
    guard (ready["code"] as? String) == "OK", let c = central else {
      log("scan: não pronto \((ready["code"] as? String) ?? "")")
      return []
    }
    queue.sync { discovered.removeAll() }
    c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    Thread.sleep(forTimeInterval: Double(max(2, min(30, seconds))))
    c.stopScan()

    let alreadyConnected = c.retrieveConnectedPeripherals(withServices: Array(MwPrinterPlugin.knownServices))
    var out: [[String: Any]] = []
    queue.sync {
      for p in alreadyConnected where discovered[p.identifier] == nil {
        discovered[p.identifier] = (p, p.name ?? "", 0, true)
      }
      for (id, v) in discovered {
        out.append(["id": id.uuidString, "name": v.1, "transport": "ble",
                    "bonded": false, "rssi": v.2, "isPrinter": v.3])
      }
    }
    log("scan: \(out.count) dispositivos")
    return out
  }

  // MARK: - Conexão

  private func isConnected(_ id: String?) -> Bool {
    guard let p = peripheral, p.state == .connected, writeChar != nil else { return false }
    if let id = id, let u = UUID(uuidString: id) { return p.identifier == u }
    return true
  }

  private func connect(id: String, transport: String, timeout: Double) -> [String: Any?] {
    if transport == "classic" { return status("CLASSIC_NOT_SUPPORTED_IOS") }
    let ready = readyStatus()
    if (ready["code"] as? String) != "OK" { return ready }
    guard let c = central else { return status("BT_UNSUPPORTED") }
    guard let uuid = UUID(uuidString: id) else {
      // Um endereço MAC (salvo no Android) não serve no iPhone.
      return status("NOT_FOUND", "id não é um UUID iOS: \(id)")
    }
    if isConnected(id) { return status("OK", "já conectado", "ble") }
    disconnect()

    var p: CBPeripheral? = c.retrievePeripherals(withIdentifiers: [uuid]).first
    if p == nil {
      log("connect: periférico desconhecido, buscando…")
      _ = scan(seconds: 4)
      p = c.retrievePeripherals(withIdentifiers: [uuid]).first
    }
    guard let per = p else { return status("NOT_FOUND") }

    var lastErr = ""
    for attempt in 1...3 {
      log("connect: \(per.name ?? "?") tentativa \(attempt)")
      let sem = DispatchSemaphore(value: 0)
      connectSem = sem
      connectError = nil
      per.delegate = self
      c.connect(per, options: nil)
      let timedOut = sem.wait(timeout: .now() + timeout) == .timedOut
      connectSem = nil
      if timedOut || connectError != nil {
        lastErr = timedOut ? "timeout" : (connectError ?? "")
        c.cancelPeripheralConnection(per)
        Thread.sleep(forTimeInterval: 0.5 * Double(attempt))
        continue
      }
      peripheral = per

      let ssem = DispatchSemaphore(value: 0)
      servicesSem = ssem
      per.discoverServices(nil)
      let sTimeout = ssem.wait(timeout: .now() + 10) == .timedOut
      servicesSem = nil
      if sTimeout { lastErr = "timeout serviços"; disconnect(); continue }

      let services = per.services ?? []
      if !services.isEmpty {
        let csem = DispatchSemaphore(value: 0)
        queue.sync { charsPending = services.count; charsSem = csem }
        for s in services { per.discoverCharacteristics(nil, for: s) }
        _ = csem.wait(timeout: .now() + 10)
        queue.sync { charsSem = nil }
      }

      guard let ch = pickWriteCharacteristic(per) else {
        let list = services.map { $0.uuid.uuidString }.joined(separator: ",")
        disconnect()
        return status("NO_WRITE_CHANNEL", "serviços=\(list)", "ble")
      }
      writeChar = ch
      log("connect: canal \(ch.service?.uuid.uuidString ?? "?")/\(ch.uuid.uuidString) max=\(per.maximumWriteValueLength(for: .withoutResponse))")
      return status("OK", "", "ble")
    }
    disconnect()
    return status("CONNECT_FAIL", lastErr, "ble")
  }

  private func pickWriteCharacteristic(_ p: CBPeripheral) -> CBCharacteristic? {
    func writable(_ c: CBCharacteristic) -> Bool {
      return c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)
    }
    let services = p.services ?? []
    for (svc, chr) in MwPrinterPlugin.writeProfiles {
      if let s = services.first(where: { $0.uuid == svc }),
         let c = s.characteristics?.first(where: { $0.uuid == chr }), writable(c) {
        return c
      }
    }
    for s in services where MwPrinterPlugin.knownServices.contains(s.uuid) {
      if let c = s.characteristics?.first(where: writable) { return c }
    }
    let candidates = services
      .filter { !MwPrinterPlugin.ignoredServices.contains($0.uuid) }
      .flatMap { $0.characteristics ?? [] }
      .filter(writable)
    return candidates.first(where: { $0.properties.contains(.writeWithoutResponse) }) ?? candidates.first
  }

  private func disconnect() {
    if let p = peripheral, let c = central { c.cancelPeripheralConnection(p) }
    peripheral = nil
    writeChar = nil
  }

  // MARK: - Escrita

  private func write(_ data: Data) -> [String: Any?] {
    guard let p = peripheral, let ch = writeChar, p.state == .connected else {
      return status("NOT_CONNECTED", "", "ble")
    }
    if data.isEmpty { return status("OK", "", "ble") }
    let noResp = ch.properties.contains(.writeWithoutResponse)
    let type: CBCharacteristicWriteType = noResp ? .withoutResponse : .withResponse
    // Impressoras baratas têm buffer pequeno: limitar o bloco.
    let maxLen = max(20, min(180, p.maximumWriteValueLength(for: type)))

    var offset = 0
    while offset < data.count {
      if p.state != .connected { disconnect(); return status("WRITE_FAIL", "desconectou", "ble") }
      let end = min(offset + maxLen, data.count)
      let part = data.subdata(in: offset..<end)

      if noResp {
        // Controle de fluxo: espera o buffer do iOS liberar.
        var waited = 0.0
        while !p.canSendWriteWithoutResponse && waited < 3.0 {
          let sem = DispatchSemaphore(value: 0)
          writeSem = sem
          _ = sem.wait(timeout: .now() + 0.1)
          writeSem = nil
          waited += 0.1
        }
        p.writeValue(part, for: ch, type: .withoutResponse)
        Thread.sleep(forTimeInterval: 0.004)
      } else {
        let sem = DispatchSemaphore(value: 0)
        writeSem = sem
        writeError = nil
        p.writeValue(part, for: ch, type: .withResponse)
        let timedOut = sem.wait(timeout: .now() + 4) == .timedOut
        writeSem = nil
        if timedOut { disconnect(); return status("WRITE_FAIL", "sem confirmação", "ble") }
        if let e = writeError { disconnect(); return status("WRITE_FAIL", e, "ble") }
      }
      offset = end
    }
    Thread.sleep(forTimeInterval: 0.2)
    log("write: \(data.count) bytes OK")
    return status("OK", "", "ble")
  }

  // MARK: - CBCentralManagerDelegate

  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    log("central state=\(central.state.rawValue)")
    if central.state != .unknown && central.state != .resetting { readySem?.signal() }
    if central.state != .poweredOn { peripheral = nil; writeChar = nil }
  }

  public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                             advertisementData: [String: Any], rssi RSSI: NSNumber) {
    let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
    if name.isEmpty { return }
    let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
    let isP = looksLikePrinter(name, uuids)
    let rssi = RSSI.intValue == 127 ? 0 : RSSI.intValue
    if let prev = discovered[peripheral.identifier] {
      discovered[peripheral.identifier] = (peripheral, name, max(prev.2, rssi), prev.3 || isP)
    } else {
      discovered[peripheral.identifier] = (peripheral, name, rssi, isP)
    }
  }

  public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    connectSem?.signal()
  }

  public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    connectError = error?.localizedDescription ?? "falha ao conectar"
    connectSem?.signal()
  }

  public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    log("desconectado \(peripheral.identifier) \(error?.localizedDescription ?? "")")
    if peripheral.identifier == self.peripheral?.identifier {
      writeError = "desconectou"
      writeSem?.signal()
    }
  }

  // MARK: - CBPeripheralDelegate

  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    servicesSem?.signal()
  }

  public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    charsPending -= 1
    if charsPending <= 0 { charsSem?.signal() }
  }

  public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    if let e = error { writeError = e.localizedDescription }
    writeSem?.signal()
  }

  public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    writeSem?.signal()
  }
}
