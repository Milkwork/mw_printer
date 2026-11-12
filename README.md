# mw_printer

Impressão em impressoras térmicas Bluetooth para Flutter/FlutterFlow.

| | Android | iOS |
|---|---|---|
| Bluetooth Clássico (SPP) | ✅ busca, **pareamento dentro do app (PIN automático)**, conexão | ❌ (a Apple não permite sem MFi) |
| BLE | ✅ | ✅ |
| Gerador ESC/POS (58/80mm, acentos, colunas, QR, código de barras) | ✅ | ✅ |

Sem dependências de terceiros, então não há licença paga.

## Instalação

```yaml
dependencies:
  mw_printer:
    git:
      url: https://github.com/<sua-org>/mw_printer.git
      ref: v1.0.0   # use uma tag
```

**Android.** O plugin já declara `BLUETOOTH_SCAN` (com `neverForLocation`), `BLUETOOTH_CONNECT` e as permissões antigas com `maxSdkVersion=30`. O app precisa declarar `ACCESS_FINE_LOCATION`, porque a busca precisa dela no Android 11 ou anterior.

**iOS.** No `Info.plist`, coloque `NSBluetoothAlwaysUsageDescription`.

## Uso

```dart
final ready = await MwPrinter.checkReady();          // pede permissões e liga o BT
final devices = await MwPrinter.scan();              // Clássico + BLE + pareados
await MwPrinter.connect(devices.first.id);           // pareia sozinho se precisar

final bytes = (EscPosBuilder(width: PaperWidth.mm58)
      ..text('MINHA EMPRESA', align: EscAlign.center, bold: true, size: 2)
      ..leftRight('Volume', '1.234 L')
      ..separator()
      ..qrCode('123456')
      ..cut())
    .build();

final r = await MwPrinter.printBytes(devices.first.id, bytes); // reconecta sozinho
if (!r.ok) print('${r.code}: ${r.message} | ${r.detail}');
print(MwPrinter.takeLogs()); // log completo para suporte
```

Todas as operações retornam um `PrinterStatus` com `code`, que é um destes:
`OK`, `BT_OFF`, `NO_PERMISSION`, `PERMISSION_PERMANENTLY_DENIED`, `LOCATION_OFF`,
`NOT_FOUND`, `PAIR_FAIL`, `CONNECT_FAIL`, `NO_WRITE_CHANNEL`, `WRITE_FAIL`,
`NOT_CONNECTED`, `CLASSIC_NOT_SUPPORTED_IOS`, `BT_UNSUPPORTED`.

## Como funciona

- **Conexão automática:** no Android tenta Clássico primeiro e BLE em seguida, e guarda o tipo que funcionou para cada impressora. No iOS usa só BLE.
- **Clássico:** se a impressora não estiver pareada, o plugin pareia e responde o PIN sozinho (`0000`, `1234`, `1111`, `8888`). O socket tenta três modos de conexão (seguro, inseguro e canal 1), que é o que resolve Samsung e Xiaomi.
- **BLE:** conexão direta, com nova tentativa e limpeza de cache quando aparece o erro 133. O MTU é pedido uma vez só. O canal de escrita é escolhido pela lista de UUIDs conhecidos de impressora. A escrita tem controle de fluxo, em blocos de até 180 bytes.
- **Fila:** as operações são executadas uma de cada vez, o que evita os erros de "GATT busy".

## App de teste

Na pasta `example/` há um app que busca, pareia, conecta e imprime uma página de teste, mostrando o log na tela:

```
cd example && flutter run
```
