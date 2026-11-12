/// mw_printer — impressão térmica Bluetooth (Clássico + BLE) para Android/iOS.
///
/// Uso típico:
/// ```dart
/// final ready = await MwPrinter.checkReady();
/// final devices = await MwPrinter.scan();
/// await MwPrinter.pair(devices.first);          // só faz algo no Clássico/Android
/// await MwPrinter.connect(devices.first.id);
/// final bytes = (EscPosBuilder(width: PaperWidth.mm58)
///       ..text('Olá, mundo!', align: EscAlign.center, bold: true)
///       ..feed(3)
///       ..cut())
///     .build();
/// await MwPrinter.printBytes(devices.first.id, bytes);
/// ```
library mw_printer;

export 'src/models.dart';
export 'src/escpos.dart';
export 'src/mw_printer_api.dart';
