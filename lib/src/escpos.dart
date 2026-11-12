import 'dart:typed_data';

/// Largura do papel.
enum PaperWidth {
  mm58(32),
  mm80(48);

  /// Quantidade de colunas em fonte normal.
  final int columns;
  const PaperWidth(this.columns);

  static PaperWidth parse(dynamic v) {
    final s = '$v'.toLowerCase();
    return (s.contains('80') || s == '48') ? PaperWidth.mm80 : PaperWidth.mm58;
  }
}

enum EscAlign { left, center, right }

/// Como os acentos são enviados.
enum EscCharset {
  /// Remove acentos (á→a). Funciona em QUALQUER impressora. Padrão.
  ascii,

  /// Página de código PC860 (Português). Acentos reais, se a impressora suportar.
  cp860,

  /// Página de código PC850 (Multilíngue).
  cp850;

  static EscCharset parse(String? v) {
    switch ((v ?? '').toLowerCase()) {
      case 'cp860':
        return EscCharset.cp860;
      case 'cp850':
        return EscCharset.cp850;
      default:
        return EscCharset.ascii;
    }
  }
}

/// Gerador de comandos ESC/POS.
///
/// Compatível com Knup, Epson, Elgin, Bematech (modo ESC/POS), Goojprt, MPT,
/// Datecs (modo ESC/POS) e a grande maioria das térmicas genéricas.
class EscPosBuilder {
  final PaperWidth width;
  final EscCharset charset;
  final BytesBuilder _b = BytesBuilder(copy: false);

  EscPosBuilder({
    this.width = PaperWidth.mm58,
    this.charset = EscCharset.ascii,
    bool initialize = true,
  }) {
    if (initialize) reset();
  }

  int get columns => width.columns;

  /// ESC @ (reinicia) + página de código.
  void reset() {
    _b.add([0x1B, 0x40]);
    switch (charset) {
      case EscCharset.cp860:
        _b.add([0x1B, 0x74, 3]);
        break;
      case EscCharset.cp850:
        _b.add([0x1B, 0x74, 2]);
        break;
      case EscCharset.ascii:
        _b.add([0x1B, 0x74, 0]);
        break;
    }
  }

  /// Bytes crus (para comandos específicos de algum modelo).
  void raw(List<int> bytes) => _b.add(bytes);

  void align(EscAlign a) => _b.add([0x1B, 0x61, a.index]);

  void bold(bool on) => _b.add([0x1B, 0x45, on ? 1 : 0]);

  void underline(bool on) => _b.add([0x1B, 0x2D, on ? 1 : 0]);

  /// Tamanho do caractere: 1 a 8 (largura e altura).
  void size({int width = 1, int height = 1}) {
    final w = (width.clamp(1, 8) - 1);
    final h = (height.clamp(1, 8) - 1);
    _b.add([0x1D, 0x21, (w << 4) | h]);
  }

  /// Escreve texto (sem quebra de linha no final, a não ser que [newLine]).
  void write(String text) => _b.add(encode(text));

  /// Uma linha de texto com formatação. A formatação é desfeita ao final.
  void text(
    String text, {
    EscAlign align = EscAlign.left,
    bool bold = false,
    bool underline = false,
    int size = 1,
    bool newLine = true,
  }) {
    this.align(align);
    if (size > 1) this.size(width: size, height: size);
    if (bold) this.bold(true);
    if (underline) this.underline(true);
    write(newLine ? '$text\n' : text);
    if (underline) this.underline(false);
    if (bold) this.bold(false);
    if (size > 1) this.size();
    if (align != EscAlign.left) this.align(EscAlign.left);
  }

  /// Linha separadora ocupando toda a largura.
  void separator([String char = '-']) =>
      text(char * columns, align: EscAlign.left);

  /// Texto à esquerda e à direita na mesma linha: "Volume ........ 120 L".
  void leftRight(String left, String right,
      {String fill = ' ', bool bold = false}) {
    final l = _clean(left);
    final r = _clean(right);
    var space = columns - l.length - r.length;
    if (space < 1) {
      // Não cabe: quebra em duas linhas.
      text(l, bold: bold);
      text(r, align: EscAlign.right, bold: bold);
      return;
    }
    text('$l${fill * space}$r', bold: bold);
  }

  /// Colunas com larguras proporcionais (soma dos [flex] = largura total).
  void columnsRow(List<String> cells, List<int> flex,
      {List<EscAlign>? aligns, bool bold = false}) {
    assert(cells.length == flex.length);
    final total = flex.fold<int>(0, (a, b) => a + b);
    final widths = <int>[];
    var used = 0;
    for (var i = 0; i < flex.length; i++) {
      final w = i == flex.length - 1
          ? columns - used
          : (columns * flex[i] / total).floor();
      widths.add(w);
      used += w;
    }
    final sb = StringBuffer();
    for (var i = 0; i < cells.length; i++) {
      var c = _clean(cells[i]);
      final w = widths[i];
      if (c.length > w) c = c.substring(0, w);
      final a = aligns != null && i < aligns.length ? aligns[i] : EscAlign.left;
      switch (a) {
        case EscAlign.right:
          sb.write(c.padLeft(w));
          break;
        case EscAlign.center:
          final pad = w - c.length;
          sb.write(' ' * (pad ~/ 2) + c + ' ' * (pad - pad ~/ 2));
          break;
        case EscAlign.left:
          sb.write(c.padRight(w));
          break;
      }
    }
    text(sb.toString(), bold: bold);
  }

  /// Avança [lines] linhas.
  void feed([int lines = 1]) => _b.add([0x1B, 0x64, lines.clamp(0, 255)]);

  /// Corte (ignorado por impressoras sem guilhotina). Avança antes de cortar.
  void cut({bool partial = true, int feedLines = 3}) {
    feed(feedLines);
    _b.add([0x1D, 0x56, partial ? 0x42 : 0x41, 0x00]);
  }

  /// QR Code (GS ( k). [moduleSize] 1..16.
  void qrCode(String data,
      {int moduleSize = 6, EscAlign align = EscAlign.center}) {
    this.align(align);
    final d = encode(data);
    final len = d.length + 3;
    final pL = len & 0xFF, pH = (len >> 8) & 0xFF;
    _b.add([0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00]); // modelo 2
    _b.add([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, moduleSize.clamp(1, 16)]);
    _b.add([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x31]); // correção M
    _b.add([0x1D, 0x28, 0x6B, pL, pH, 0x31, 0x50, 0x30]);
    _b.add(d);
    _b.add([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30]); // imprime
    _b.add([0x0A]);
    this.align(EscAlign.left);
  }

  /// Código de barras CODE128.
  void barcode128(String data,
      {int height = 80, bool showText = true, EscAlign align = EscAlign.center}) {
    this.align(align);
    final d = [0x7B, 0x42, ...encode(data)]; // {B = conjunto B
    _b.add([0x1D, 0x68, height.clamp(1, 255)]);
    _b.add([0x1D, 0x77, 2]);
    _b.add([0x1D, 0x48, showText ? 2 : 0]);
    _b.add([0x1D, 0x6B, 73, d.length, ...d]);
    _b.add([0x0A]);
    this.align(EscAlign.left);
  }

  Uint8List build() => _b.toBytes();

  // ---------------------------------------------------------------------------
  // Codificação de texto
  // ---------------------------------------------------------------------------

  String _clean(String s) =>
      s.replaceAll('\r', '').replaceAll('\n', ' ').replaceAll('\t', ' ');

  /// Converte a string para bytes na página de código escolhida.
  List<int> encode(String s) {
    final out = <int>[];
    for (final rune in s.runes) {
      if (rune < 0x80) {
        out.add(rune);
        continue;
      }
      final ch = String.fromCharCode(rune);
      if (charset == EscCharset.cp860) {
        final c = _cp860[ch];
        if (c != null) {
          out.add(c);
          continue;
        }
      } else if (charset == EscCharset.cp850) {
        final c = _cp850[ch];
        if (c != null) {
          out.add(c);
          continue;
        }
      }
      out.addAll(_fallback(ch).codeUnits);
    }
    return out;
  }

  static String _fallback(String ch) {
    final r = _ascii[ch];
    if (r != null) return r;
    return '?';
  }

  /// Remove acentos de um texto (útil fora do builder).
  static String removeAccents(String s) {
    final sb = StringBuffer();
    for (final rune in s.runes) {
      if (rune < 0x80) {
        sb.writeCharCode(rune);
      } else {
        sb.write(_fallback(String.fromCharCode(rune)));
      }
    }
    return sb.toString();
  }

  static const Map<String, String> _ascii = {
    'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
    'ç': 'c', 'ñ': 'n',
    'Á': 'A', 'À': 'A', 'Â': 'A', 'Ã': 'A', 'Ä': 'A', 'Å': 'A',
    'É': 'E', 'È': 'E', 'Ê': 'E', 'Ë': 'E',
    'Í': 'I', 'Ì': 'I', 'Î': 'I', 'Ï': 'I',
    'Ó': 'O', 'Ò': 'O', 'Ô': 'O', 'Õ': 'O', 'Ö': 'O',
    'Ú': 'U', 'Ù': 'U', 'Û': 'U', 'Ü': 'U',
    'Ç': 'C', 'Ñ': 'N',
    'º': 'o', 'ª': 'a', '°': 'o', '²': '2', '³': '3',
    '–': '-', '—': '-', '‘': "'", '’': "'", '“': '"', '”': '"',
    '…': '...', '•': '*', '€': 'EUR', ' ': ' ',
  };

  static const Map<String, int> _cp860 = {
    'Ç': 0x80, 'ü': 0x81, 'é': 0x82, 'â': 0x83, 'ã': 0x84, 'à': 0x85,
    'Á': 0x86, 'ç': 0x87, 'ê': 0x88, 'Ê': 0x89, 'è': 0x8A, 'Í': 0x8B,
    'Ô': 0x8C, 'ì': 0x8D, 'Ã': 0x8E, 'Â': 0x8F, 'É': 0x90, 'À': 0x91,
    'È': 0x92, 'ô': 0x93, 'õ': 0x94, 'ò': 0x95, 'Ú': 0x96, 'ù': 0x97,
    'Ì': 0x98, 'Õ': 0x99, 'Ü': 0x9A, 'Ù': 0x9D, 'Ó': 0x9F,
    'á': 0xA0, 'í': 0xA1, 'ó': 0xA2, 'ú': 0xA3, 'ñ': 0xA4, 'Ñ': 0xA5,
    'ª': 0xA6, 'º': 0xA7, 'Ò': 0xA9, '°': 0xF8,
  };

  static const Map<String, int> _cp850 = {
    'Ç': 0x80, 'ü': 0x81, 'é': 0x82, 'â': 0x83, 'ä': 0x84, 'à': 0x85,
    'ç': 0x87, 'ê': 0x88, 'ë': 0x89, 'è': 0x8A, 'ï': 0x8B, 'î': 0x8C,
    'ì': 0x8D, 'Ä': 0x8E, 'É': 0x90, 'ô': 0x93, 'ö': 0x94, 'ò': 0x95,
    'û': 0x96, 'ù': 0x97, 'Ö': 0x99, 'Ü': 0x9A,
    'á': 0xA0, 'í': 0xA1, 'ó': 0xA2, 'ú': 0xA3, 'ñ': 0xA4, 'Ñ': 0xA5,
    'ª': 0xA6, 'º': 0xA7, 'Á': 0xB5, 'Â': 0xB6, 'À': 0xB7,
    'ã': 0xC6, 'Ã': 0xC7, 'Ê': 0xD2, 'Ë': 0xD3, 'È': 0xD4, 'Í': 0xD6,
    'Î': 0xD7, 'Ï': 0xD8, 'Ó': 0xE0, 'Ô': 0xE2, 'Ò': 0xE3, 'õ': 0xE4,
    'Õ': 0xE5, 'Ú': 0xE9, 'Û': 0xEA, 'Ù': 0xEB, '°': 0xF8,
  };
}
