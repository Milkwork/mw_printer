import 'package:flutter/material.dart';
import 'package:mw_printer/mw_printer.dart';

void main() => runApp(const MaterialApp(home: PrinterTestPage()));

/// App de teste do mw_printer: buscar, parear, conectar e imprimir.
class PrinterTestPage extends StatefulWidget {
  const PrinterTestPage({super.key});

  @override
  State<PrinterTestPage> createState() => _PrinterTestPageState();
}

class _PrinterTestPageState extends State<PrinterTestPage> {
  List<PrinterDevice> _devices = [];
  PrinterDevice? _selected;
  bool _busy = false;
  bool _onlyPrinters = true;
  PaperWidth _width = PaperWidth.mm58;
  EscCharset _charset = EscCharset.ascii;
  String _status = 'Pronto';
  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    MwPrinter.onLog = (l) {
      if (!mounted) return;
      setState(() {
        _log.insert(0, l);
        if (_log.length > 200) _log.removeLast();
      });
    };
  }

  Future<void> _run(String label, Future<String> Function() task) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '$label…';
    });
    try {
      final r = await task();
      if (mounted) setState(() => _status = r);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() => _run('Buscando', () async {
        final ready = await MwPrinter.checkReady();
        if (!ready.ok) return ready.message;
        final list = await MwPrinter.scan(onlyPrinters: _onlyPrinters);
        setState(() => _devices = list);
        return '${list.length} encontrados';
      });

  Future<void> _pairAndConnect(PrinterDevice d) => _run('Conectando', () async {
        _selected = d;
        final p = await MwPrinter.pair(d.id);
        if (!p.ok) return p.message;
        final c = await MwPrinter.connect(d.id);
        return c.ok ? 'Conectado (${c.transport?.name})' : c.message;
      });

  Future<void> _printTest() => _run('Imprimindo', () async {
        final d = _selected;
        if (d == null) return 'Selecione uma impressora';
        final b = EscPosBuilder(width: _width, charset: _charset)
          ..text('TESTE DE IMPRESSÃO', align: EscAlign.center, bold: true, size: 2)
          ..feed()
          ..text('Impressora: ${d.name}')
          ..text('Tipo: ${d.transport.name}')
          ..text('Acentos: áéíóú ãõ ç ÁÉÍÓÚ ÃÕ Ç')
          ..separator()
          ..leftRight('Volume', '1.234 L')
          ..columnsRow(['Data', 'Gord.', 'Prot.', 'CCS'], [3, 2, 2, 2], bold: true)
          ..columnsRow(['10/11/26', '3,45', '3,10', '250'], [3, 2, 2, 2])
          ..separator('=')
          ..qrCode('https://exemplo.com.br')
          ..cut();
        final r = await MwPrinter.printBytes(d.id, b.build());
        return r.ok ? 'Impresso (${r.transport?.name})' : '${r.message}\n${r.detail}';
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('mw_printer — teste')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            FilledButton(onPressed: _busy ? null : _scan, child: const Text('Buscar')),
            FilledButton.tonal(onPressed: _busy ? null : _printTest, child: const Text('Imprimir teste')),
            OutlinedButton(
                onPressed: _busy ? null : () => _run('Desconectando', () async {
                      await MwPrinter.disconnect();
                      return 'Desconectado';
                    }),
                child: const Text('Desconectar')),
            FilterChip(
                label: const Text('Só impressoras'),
                selected: _onlyPrinters,
                onSelected: (v) => setState(() => _onlyPrinters = v)),
            DropdownButton<PaperWidth>(
                value: _width,
                items: PaperWidth.values
                    .map((w) => DropdownMenuItem(value: w, child: Text(w.name)))
                    .toList(),
                onChanged: (v) => setState(() => _width = v!)),
            DropdownButton<EscCharset>(
                value: _charset,
                items: EscCharset.values
                    .map((c) => DropdownMenuItem(value: c, child: Text(c.name)))
                    .toList(),
                onChanged: (v) => setState(() => _charset = v!)),
          ]),
        ),
        if (_busy) const LinearProgressIndicator(),
        Padding(padding: const EdgeInsets.all(8), child: Text(_status)),
        Expanded(
          flex: 3,
          child: ListView(children: [
            for (final d in _devices)
              ListTile(
                selected: _selected?.id == d.id,
                leading: Icon(d.isPrinter ? Icons.print : Icons.bluetooth),
                title: Text(d.name),
                subtitle: Text('${d.id} • ${d.transport.name}'
                    '${d.bonded ? ' • pareada' : ''} • ${d.rssi} dBm'),
                onTap: _busy ? null : () => _pairAndConnect(d),
              ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          flex: 2,
          child: ListView(
            padding: const EdgeInsets.all(8),
            children: [for (final l in _log) Text(l, style: const TextStyle(fontSize: 11, fontFamily: 'monospace'))],
          ),
        ),
      ]),
    );
  }
}
