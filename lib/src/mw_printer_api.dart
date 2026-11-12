import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

/// API principal. Todas as operações são serializadas (uma de cada vez),
/// o que evita a maior parte dos erros de "GATT busy" / socket ocupado.
class MwPrinter {
  MwPrinter._();

  static const MethodChannel _ch = MethodChannel('br.com.milkwork/mw_printer');

  static bool _handlerSet = false;
  static Future<void> _queue = Future.value();

  /// Últimas linhas de log (nativo + Dart). Útil para enviar ao suporte.
  static final List<String> logs = <String>[];
  static const int _maxLogs = 300;

  /// Callback opcional para cada linha de log.
  static void Function(String line)? onLog;

  /// Habilita logs no console (debugPrint).
  static bool debug = kDebugMode;

  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'log') _log('[native] ${call.arguments}');
      return null;
    });
  }

  static void _log(String msg) {
    final line = '${DateTime.now().toIso8601String().substring(11, 23)} $msg';
    logs.add(line);
    if (logs.length > _maxLogs) logs.removeRange(0, logs.length - _maxLogs);
    if (debug) debugPrint('[mw_printer] $line');
    onLog?.call(line);
  }

  /// Retorna os logs acumulados em um único texto e (opcionalmente) limpa.
  static String takeLogs({bool clear = true}) {
    final s = logs.join('\n');
    if (clear) logs.clear();
    return s;
  }

  /// Executa [task] em fila (exclusão mútua).
  static Future<T> _serial<T>(Future<T> Function() task) {
    _ensureHandler();
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  static Future<PrinterStatus> _invokeStatus(String method,
      [Map<String, dynamic>? args]) async {
    try {
      final r = await _ch.invokeMethod<Map<dynamic, dynamic>>(method, args);
      final st = PrinterStatus.fromMap(r);
      _log('$method -> ${st.code}${st.detail.isEmpty ? '' : ' (${st.detail})'}');
      return st;
    } on PlatformException catch (e) {
      _log('$method -> PlatformException ${e.code} ${e.message}');
      return PrinterStatus.error(PrinterCode.unknown, '${e.code}: ${e.message}');
    } on MissingPluginException catch (e) {
      _log('$method -> MissingPluginException $e');
      return PrinterStatus.error(PrinterCode.btUnsupported, '$e');
    } catch (e) {
      _log('$method -> $e');
      return PrinterStatus.error(PrinterCode.unknown, '$e');
    }
  }

  static bool get isIOS => !kIsWeb && Platform.isIOS;
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  // ---------------------------------------------------------------------------
  // Prontidão / permissões
  // ---------------------------------------------------------------------------

  /// Verifica (e por padrão solicita) permissões, Bluetooth ligado e,
  /// quando necessário, Localização ligada.
  ///
  /// [forScan] = false pula as exigências que só valem para a busca
  /// (permissão de busca/Localização), útil antes de imprimir.
  static Future<PrinterStatus> checkReady(
          {bool request = true, bool forScan = true}) =>
      _serial(() => _invokeStatus(
          'checkReady', {'request': request, 'forScan': forScan}));

  /// Abre o diálogo do sistema para ligar o Bluetooth (Android).
  /// No iOS retorna o estado atual (o iOS não permite ligar via app).
  static Future<PrinterStatus> requestEnableBluetooth() =>
      _serial(() => _invokeStatus('requestEnable'));

  /// Abre as configurações do app (para liberar permissão negada).
  static Future<void> openAppSettings() =>
      _serial(() => _invokeStatus('openAppSettings'));

  /// Abre as configurações de Localização (Android).
  static Future<void> openLocationSettings() =>
      _serial(() => _invokeStatus('openLocationSettings'));

  // ---------------------------------------------------------------------------
  // Busca
  // ---------------------------------------------------------------------------

  /// Busca impressoras por [seconds] segundos.
  ///
  /// Android: Clássico (descoberta) + BLE ao mesmo tempo, mais os já pareados.
  /// iOS: BLE.
  /// [onlyPrinters] filtra pela heurística de impressora (com fallback: se nada
  /// for reconhecido como impressora, retorna todos os dispositivos com nome).
  static Future<List<PrinterDevice>> scan({
    int seconds = 8,
    bool onlyPrinters = true,
    bool includeBonded = true,
  }) =>
      _serial(() async {
        try {
          final r = await _ch.invokeMethod<List<dynamic>>('scan', {
            'seconds': seconds,
            'includeBonded': includeBonded,
          });
          final all = (r ?? [])
              .map((e) => PrinterDevice.fromMap(e as Map<dynamic, dynamic>))
              .where((d) => d.name.trim().isNotEmpty)
              .toList();
          var list = all;
          if (onlyPrinters) {
            final printers = all.where((d) => d.isPrinter).toList();
            if (printers.isNotEmpty) list = printers;
          }
          list.sort((a, b) {
            if (a.bonded != b.bonded) return a.bonded ? -1 : 1;
            if (a.isPrinter != b.isPrinter) return a.isPrinter ? -1 : 1;
            return b.rssi.compareTo(a.rssi);
          });
          _log('scan -> ${list.length} dispositivos (de ${all.length})');
          return list;
        } catch (e) {
          _log('scan -> erro $e');
          return <PrinterDevice>[];
        }
      });

  /// Dispositivos já pareados (Android). No iOS retorna lista vazia.
  static Future<List<PrinterDevice>> bondedDevices() => _serial(() async {
        try {
          final r = await _ch.invokeMethod<List<dynamic>>('bondedDevices');
          return (r ?? [])
              .map((e) => PrinterDevice.fromMap(e as Map<dynamic, dynamic>))
              .toList();
        } catch (e) {
          _log('bondedDevices -> erro $e');
          return <PrinterDevice>[];
        }
      });

  // ---------------------------------------------------------------------------
  // Pareamento
  // ---------------------------------------------------------------------------

  /// Pareia dentro do app.
  ///
  /// Android/Clássico: cria o vínculo e responde o PIN automaticamente
  /// (tenta cada PIN de [pins]). Android/BLE e iOS: não há pareamento
  /// obrigatório; retorna OK (o sistema pede confirmação sozinho se a
  /// impressora exigir criptografia).
  static Future<PrinterStatus> pair(String id,
          {List<String> pins = const ['0000', '1234', '1111', '8888'],
          int timeoutSeconds = 30}) =>
      _serial(() => _invokeStatus('pair', {
            'id': id,
            'pins': pins,
            'timeoutMs': timeoutSeconds * 1000,
          }));

  /// Remove o pareamento (Android).
  static Future<PrinterStatus> unpair(String id) =>
      _serial(() => _invokeStatus('unpair', {'id': id}));

  // ---------------------------------------------------------------------------
  // Conexão
  // ---------------------------------------------------------------------------

  /// Conecta. [transport] `null`/unknown = automático (Android: Clássico
  /// primeiro, BLE como alternativa; lembra o que funcionou. iOS: BLE).
  static Future<PrinterStatus> connect(String id,
          {PrinterTransport? transport, int timeoutSeconds = 12}) =>
      _serial(() => _connect(id, transport, timeoutSeconds));

  static Future<PrinterStatus> _connect(
      String id, PrinterTransport? transport, int timeoutSeconds) {
    if (id.trim().isEmpty) {
      return Future.value(PrinterStatus.error(PrinterCode.invalidArgument, 'id vazio'));
    }
    return _invokeStatus('connect', {
      'id': id,
      'transport': (transport ?? PrinterTransport.unknown).name,
      'timeoutMs': timeoutSeconds * 1000,
    });
  }

  static Future<bool> isConnected([String? id]) => _serial(() => _isConnected(id));

  static Future<bool> _isConnected(String? id) async {
    try {
      return (await _ch.invokeMethod<bool>('isConnected', {'id': id})) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<PrinterStatus> disconnect() =>
      _serial(() => _invokeStatus('disconnect'));

  // ---------------------------------------------------------------------------
  // Impressão
  // ---------------------------------------------------------------------------

  /// Envia [bytes] para a impressora [id].
  ///
  /// Garante a conexão (conecta se preciso) e, em caso de falha na escrita,
  /// reconecta e tenta de novo até [retries] vezes.
  static Future<PrinterStatus> printBytes(
    String id,
    List<int> bytes, {
    PrinterTransport? transport,
    int retries = 2,
    int timeoutSeconds = 12,
  }) =>
      _serial(() async {
        if (id.trim().isEmpty) {
          return PrinterStatus.error(PrinterCode.invalidArgument, 'id vazio');
        }
        if (bytes.isEmpty) return PrinterStatus.success;
        final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
        _log('printBytes id=$id bytes=${data.length}');

        PrinterStatus last = PrinterStatus.error(PrinterCode.unknown);
        for (var attempt = 0; attempt <= retries; attempt++) {
          if (attempt > 0) {
            _log('printBytes tentativa ${attempt + 1}');
            await _invokeStatus('disconnect');
            await Future.delayed(Duration(milliseconds: 700 * attempt));
          }
          if (!await _isConnected(id)) {
            final c = await _connect(id, transport, timeoutSeconds);
            if (!c.ok) {
              last = c;
              // Erros que não se resolvem tentando de novo.
              if (_isFatal(c.code)) return c;
              continue;
            }
          }
          last = await _invokeStatus('write', {'bytes': data});
          if (last.ok) return last;
          if (_isFatal(last.code)) return last;
        }
        return last;
      });

  static bool _isFatal(String code) =>
      code == PrinterCode.btOff ||
      code == PrinterCode.btUnsupported ||
      code == PrinterCode.noPermission ||
      code == PrinterCode.permissionPermanentlyDenied ||
      code == PrinterCode.locationOff ||
      code == PrinterCode.classicNotSupportedIos ||
      code == PrinterCode.noWriteChannel ||
      code == PrinterCode.invalidArgument;
}
