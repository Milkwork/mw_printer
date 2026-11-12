/// Tipo de conexão Bluetooth da impressora.
enum PrinterTransport {
  /// Bluetooth Clássico (SPP / RFCOMM). Somente Android.
  classic,

  /// Bluetooth Low Energy (GATT). Android e iOS.
  ble,

  /// Impressora que expõe Clássico e BLE (dual mode).
  dual,

  /// Desconhecido (ex.: impressora salva sem informação de tipo).
  unknown;

  static PrinterTransport parse(String? v) {
    switch (v) {
      case 'classic':
        return PrinterTransport.classic;
      case 'ble':
        return PrinterTransport.ble;
      case 'dual':
        return PrinterTransport.dual;
      default:
        return PrinterTransport.unknown;
    }
  }
}

/// Códigos de status retornados por todas as operações.
class PrinterCode {
  static const ok = 'OK';
  static const btUnsupported = 'BT_UNSUPPORTED';
  static const btOff = 'BT_OFF';
  static const noPermission = 'NO_PERMISSION';
  static const permissionPermanentlyDenied = 'PERMISSION_PERMANENTLY_DENIED';
  static const locationOff = 'LOCATION_OFF';
  static const notFound = 'NOT_FOUND';
  static const pairFail = 'PAIR_FAIL';
  static const pairCanceled = 'PAIR_CANCELED';
  static const connectFail = 'CONNECT_FAIL';
  static const noWriteChannel = 'NO_WRITE_CHANNEL';
  static const writeFail = 'WRITE_FAIL';
  static const notConnected = 'NOT_CONNECTED';
  static const classicNotSupportedIos = 'CLASSIC_NOT_SUPPORTED_IOS';
  static const busy = 'BUSY';
  static const timeout = 'TIMEOUT';
  static const invalidArgument = 'INVALID_ARGUMENT';
  static const unknown = 'UNKNOWN';
}

/// Resultado de uma operação.
class PrinterStatus {
  final bool ok;
  final String code;
  final String message;

  /// Detalhe técnico (para log), não exibir ao usuário.
  final String detail;

  /// Transporte efetivamente usado (quando aplicável).
  final PrinterTransport? transport;

  const PrinterStatus({
    required this.ok,
    required this.code,
    this.message = '',
    this.detail = '',
    this.transport,
  });

  factory PrinterStatus.fromMap(Map<dynamic, dynamic>? m) {
    if (m == null) {
      return const PrinterStatus(
          ok: false, code: PrinterCode.unknown, message: 'Sem resposta');
    }
    final code = (m['code'] as String?) ?? PrinterCode.unknown;
    return PrinterStatus(
      ok: code == PrinterCode.ok,
      code: code,
      message: (m['message'] as String?)?.isNotEmpty == true
          ? m['message'] as String
          : PrinterMessages.of(code),
      detail: (m['detail'] as String?) ?? '',
      transport: m['transport'] == null
          ? null
          : PrinterTransport.parse(m['transport'] as String?),
    );
  }

  factory PrinterStatus.error(String code, [String detail = '']) =>
      PrinterStatus(
          ok: false,
          code: code,
          message: PrinterMessages.of(code),
          detail: detail);

  static const success =
      PrinterStatus(ok: true, code: PrinterCode.ok, message: 'OK');

  @override
  String toString() =>
      'PrinterStatus($code, $message${detail.isEmpty ? '' : ' | $detail'})';
}

/// Mensagens padrão (pt-BR) para cada código.
class PrinterMessages {
  static String of(String code) {
    switch (code) {
      case PrinterCode.ok:
        return 'OK';
      case PrinterCode.btUnsupported:
        return 'Este aparelho não possui Bluetooth.';
      case PrinterCode.btOff:
        return 'O Bluetooth está desligado. Ligue o Bluetooth e tente novamente.';
      case PrinterCode.noPermission:
        return 'Permita o acesso ao Bluetooth (Dispositivos próximos) para usar a impressora.';
      case PrinterCode.permissionPermanentlyDenied:
        return 'A permissão de Bluetooth foi negada. Abra as configurações do app e permita "Dispositivos próximos".';
      case PrinterCode.locationOff:
        return 'Ative a Localização do aparelho para buscar impressoras.';
      case PrinterCode.notFound:
        return 'Impressora não encontrada. Verifique se ela está ligada e próxima.';
      case PrinterCode.pairFail:
        return 'Não foi possível parear com a impressora. Tente novamente.';
      case PrinterCode.pairCanceled:
        return 'Pareamento cancelado.';
      case PrinterCode.connectFail:
        return 'Não foi possível conectar à impressora. Verifique se ela está ligada, próxima e não conectada a outro celular.';
      case PrinterCode.noWriteChannel:
        return 'Este dispositivo não parece ser uma impressora compatível.';
      case PrinterCode.writeFail:
        return 'Falha ao enviar a impressão. Tente novamente.';
      case PrinterCode.notConnected:
        return 'A impressora não está conectada.';
      case PrinterCode.classicNotSupportedIos:
        return 'Esta impressora usa Bluetooth Clássico, que o iPhone não suporta. Use uma impressora com BLE.';
      case PrinterCode.busy:
        return 'A impressora está ocupada. Aguarde e tente novamente.';
      case PrinterCode.timeout:
        return 'A impressora demorou para responder.';
      case PrinterCode.invalidArgument:
        return 'Parâmetro inválido.';
      default:
        return 'Erro desconhecido na impressora.';
    }
  }
}

/// Dispositivo encontrado na busca ou já pareado.
class PrinterDevice {
  /// Android: endereço MAC. iOS: UUID gerado pelo iPhone.
  final String id;
  final String name;
  final PrinterTransport transport;

  /// Já pareado no sistema (Clássico/Android).
  final bool bonded;
  final int rssi;

  /// Heurística: parece uma impressora (classe de dispositivo, serviço ou nome).
  final bool isPrinter;

  const PrinterDevice({
    required this.id,
    required this.name,
    required this.transport,
    this.bonded = false,
    this.rssi = 0,
    this.isPrinter = false,
  });

  factory PrinterDevice.fromMap(Map<dynamic, dynamic> m) => PrinterDevice(
        id: m['id'] as String,
        name: (m['name'] as String?) ?? '',
        transport: PrinterTransport.parse(m['transport'] as String?),
        bonded: (m['bonded'] as bool?) ?? false,
        rssi: (m['rssi'] as int?) ?? 0,
        isPrinter: (m['isPrinter'] as bool?) ?? false,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'transport': transport.name,
        'bonded': bonded,
        'rssi': rssi,
        'isPrinter': isPrinter,
      };

  @override
  String toString() => 'PrinterDevice($name, $id, ${transport.name}'
      '${bonded ? ', pareada' : ''})';
}
