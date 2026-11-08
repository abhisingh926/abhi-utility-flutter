import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

// ---- Model --------------------------------------------------------------------------------

/// A piece of text with one formatting, or an image.
class DocRun {
  const DocRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.size,
    this.color,
    this.highlight,
    this.link = false,
    this.image,
    this.imageWidth,
    this.imageHeight,
  });

  final String text;
  final bool bold, italic, underline, strike, link;

  /// Font size in points; null = the paragraph's size.
  final double? size;

  /// ARGB colours.
  final int? color, highlight;

  /// Picture bytes (png/jpeg/gif…) and size in logical pixels.
  final Uint8List? image;
  final double? imageWidth, imageHeight;
}

sealed class DocBlock {}

class DocParagraph extends DocBlock {
  DocParagraph({
    required this.pid,
    required this.runs,
    this.style = 'normal',
    this.align = 'left',
    this.listLabel,
    this.listLevel = 0,
    this.pageBreakBefore = false,
    this.baseSize = 11,
  });

  /// Position of this `w:p` among all paragraphs of the body (document order): how
  /// the writer finds it again.
  final int pid;
  final List<DocRun> runs;

  /// normal, title, subtitle, h1 … h6.
  final String style;

  /// left, center, right, justify.
  final String align;

  /// "•", "1.", "a)"… for list items.
  final String? listLabel;
  final int listLevel;
  final bool pageBreakBefore;

  /// Default font size (points) of this paragraph's style.
  final double baseSize;

  /// The editable text: text runs only (images are kept as they are).
  String get text => runs.where((r) => r.image == null).map((r) => r.text).join();
  bool get hasImage => runs.any((r) => r.image != null);
}

class DocTable extends DocBlock {
  DocTable(this.rows);

  /// rows → cells → blocks in the cell.
  final List<List<List<DocBlock>>> rows;
}

class DocDocument {
  DocDocument(this.blocks, {this.plainText = false});
  final List<DocBlock> blocks;

  /// A .txt file: one paragraph per line, no formatting.
  final bool plainText;
}

class DocFormatException implements Exception {
  const DocFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads a .docx (or .txt) in a background isolate.
Future<DocDocument> readDocument(Uint8List bytes, String fileName) =>
    Isolate.run(() => parseDocument(bytes, fileName));

DocDocument parseDocument(Uint8List bytes, String fileName) {
  if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) return _Docx(bytes).read();
  if (bytes.length >= 4 && bytes[0] == 0xD0 && bytes[1] == 0xCF && bytes[2] == 0x11 && bytes[3] == 0xE0) {
    throw const DocFormatException(
        "This is the old Word format (.doc), which can't be opened here yet. "
        'Open it in Google Docs or Word and save it as .docx.');
  }
  if (fileName.toLowerCase().endsWith('.docx')) {
    throw const DocFormatException('This file is damaged or not really a Word document.');
  }
  return parsePlainText(bytes);
}

DocDocument parsePlainText(Uint8List bytes) {
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.startsWith('﻿')) text = text.substring(1);
  if (text.contains('\u0000')) throw const DocFormatException('This file is not a text document.');
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  var i = 0;
  return DocDocument([for (final l in lines) DocParagraph(pid: i++, runs: [DocRun(l)])], plainText: true);
}

// ---- Helpers (shared with the writer) -----------------------------------------------------

Iterable<XmlElement> docAll(XmlNode n, String local) => n.descendantElements.where((e) => e.name.local == local);
Iterable<XmlElement> docChildren(XmlNode n, String local) => n.childElements.where((e) => e.name.local == local);
XmlElement? docChild(XmlNode n, String local) => docChildren(n, local).firstOrNull;
String? docAttr(XmlElement e, String local) => e.attributes.where((a) => a.name.local == local).firstOrNull?.value;

/// Every paragraph of the body in document order: index = [DocParagraph.pid].
List<XmlElement> bodyParagraphs(XmlDocument doc) {
  final body = docAll(doc, 'body').firstOrNull;
  return body == null ? const [] : docAll(body, 'p').toList();
}

/// Is this a plain text run (text, tabs, breaks) that the editor may rewrite?
bool isTextRun(XmlElement r) => r.childElements.every((c) => const {
      'rPr', 't', 'tab', 'br', 'cr', 'noBreakHyphen', 'softHyphen', 'lastRenderedPageBreak',
    }.contains(c.name.local)) &&
    r.childElements.any((c) => c.name.local != 'rPr');

/// Text of a text run: \t for tabs, \n for line breaks.
String runText(XmlElement r) {
  final b = StringBuffer();
  for (final c in r.childElements) {
    switch (c.name.local) {
      case 't':
        b.write(c.innerText);
      case 'tab':
        b.write('\t');
      case 'br' || 'cr':
        if (docAttr(c, 'type') != 'page') b.write('\n');
      case 'noBreakHyphen':
        b.write('-');
    }
  }
  return b.toString();
}

bool _on(XmlElement? e) => e != null && !const ['0', 'false', 'none'].contains(docAttr(e, 'val'));

int? _hexColor(String? v) {
  if (v == null || v == 'auto' || v.length != 6) return null;
  final n = int.tryParse(v, radix: 16);
  return n == null ? null : 0xFF000000 | n;
}

const _highlights = {
  'yellow': 0xFFFFFF00, 'green': 0xFF00FF00, 'cyan': 0xFF00FFFF, 'magenta': 0xFFFF00FF, 'blue': 0xFF0000FF,
  'red': 0xFFFF0000, 'darkBlue': 0xFF000080, 'darkCyan': 0xFF008080, 'darkGreen': 0xFF008000,
  'darkMagenta': 0xFF800080, 'darkRed': 0xFF800000, 'darkYellow': 0xFF808000, 'darkGray': 0xFF808080,
  'lightGray': 0xFFC0C0C0, 'black': 0xFF000000,
};

// ---- DOCX ---------------------------------------------------------------------------------

class _Style {
  String? name, basedOn;
  bool? bold, italic;
  double? size;
  int? color;
  String? align, numId, ilvl;
}

class _Docx {
  _Docx(Uint8List bytes) : zip = ZipDecoder().decodeBytes(bytes);
  final Archive zip;
  final _styles = <String, _Style>{};
  final _rels = <String, String>{}; // rId → zip path
  double _defaultSize = 11;

  // numbering: numId → abstractNumId; abstract → level → (format, text)
  final _numToAbstract = <String, String>{};
  final _levels = <String, Map<int, (String, String)>>{};
  final _counters = <String, List<int>>{};

  late final Map<XmlElement, int> _pids;

  String? _text(String path) {
    final f = zip.findFile(path);
    return f == null ? null : utf8.decode(f.content, allowMalformed: true);
  }

  DocDocument read() {
    final xml = _text('word/document.xml');
    if (xml == null) throw const DocFormatException('This is not a Word document.');
    _readStyles();
    _readNumbering();
    final relsXml = _text('word/_rels/document.xml.rels');
    if (relsXml != null) {
      for (final r in docAll(XmlDocument.parse(relsXml), 'Relationship')) {
        var t = docAttr(r, 'Target') ?? '';
        if (docAttr(r, 'TargetMode') == 'External') continue;
        t = t.startsWith('/') ? t.substring(1) : 'word/$t';
        _rels[docAttr(r, 'Id') ?? ''] = t;
      }
    }
    final doc = XmlDocument.parse(xml);
    final paragraphs = bodyParagraphs(doc);
    _pids = {for (var i = 0; i < paragraphs.length; i++) paragraphs[i]: i};
    final body = docAll(doc, 'body').firstOrNull;
    return DocDocument(body == null ? [] : _blocks(body));
  }

  void _readStyles() {
    final xml = _text('word/styles.xml');
    if (xml == null) return;
    final doc = XmlDocument.parse(xml);
    final defSz = docAll(doc, 'rPrDefault').map((e) => docAll(e, 'sz').firstOrNull).nonNulls.firstOrNull;
    final d = double.tryParse(defSz == null ? '' : docAttr(defSz, 'val') ?? '');
    if (d != null) _defaultSize = d / 2;
    for (final s in docAll(doc, 'style')) {
      if (docAttr(s, 'type') != 'paragraph') continue;
      final st = _Style()
        ..name = docAttr(docChild(s, 'name') ?? s, 'val')?.toLowerCase()
        ..basedOn = docAttr(docChild(s, 'basedOn') ?? s, 'val');
      final rPr = docChild(s, 'rPr');
      if (rPr != null) {
        if (docChild(rPr, 'b') != null) st.bold = _on(docChild(rPr, 'b'));
        if (docChild(rPr, 'i') != null) st.italic = _on(docChild(rPr, 'i'));
        final sz = double.tryParse(docAttr(docChild(rPr, 'sz') ?? rPr, 'val') ?? '');
        if (sz != null) st.size = sz / 2;
        st.color = _hexColor(docAttr(docChild(rPr, 'color') ?? rPr, 'val'));
      }
      final pPr = docChild(s, 'pPr');
      if (pPr != null) {
        st.align = docAttr(docChild(pPr, 'jc') ?? pPr, 'val');
        final numPr = docChild(pPr, 'numPr');
        if (numPr != null) {
          st.numId = docAttr(docChild(numPr, 'numId') ?? numPr, 'val');
          st.ilvl = docAttr(docChild(numPr, 'ilvl') ?? numPr, 'val');
        }
      }
      final id = docAttr(s, 'styleId');
      if (id != null) _styles[id] = st;
    }
  }

  /// A style property, following basedOn.
  T? _styleProp<T>(String? id, T? Function(_Style s) get) {
    var depth = 0;
    while (id != null && depth++ < 10) {
      final s = _styles[id];
      if (s == null) return null;
      final v = get(s);
      if (v != null) return v;
      id = s.basedOn;
    }
    return null;
  }

  void _readNumbering() {
    final xml = _text('word/numbering.xml');
    if (xml == null) return;
    final doc = XmlDocument.parse(xml);
    for (final a in docAll(doc, 'abstractNum')) {
      final id = docAttr(a, 'abstractNumId');
      if (id == null) continue;
      final lv = <int, (String, String)>{};
      for (final l in docChildren(a, 'lvl')) {
        final i = int.tryParse(docAttr(l, 'ilvl') ?? '') ?? 0;
        lv[i] = (docAttr(docChild(l, 'numFmt') ?? l, 'val') ?? 'bullet', docAttr(docChild(l, 'lvlText') ?? l, 'val') ?? '');
      }
      _levels[id] = lv;
    }
    for (final n in docAll(doc, 'num')) {
      final id = docAttr(n, 'numId');
      final abs = docAttr(docChild(n, 'abstractNumId') ?? n, 'val');
      if (id != null && abs != null) _numToAbstract[id] = abs;
    }
  }

  List<DocBlock> _blocks(XmlElement container) {
    final out = <DocBlock>[];
    for (final e in container.childElements) {
      switch (e.name.local) {
        case 'p':
          out.add(_paragraph(e));
        case 'tbl':
          out.add(_table(e));
        case 'sdt': // content controls: show what's inside
          final content = docChild(e, 'sdtContent');
          if (content != null) out.addAll(_blocks(content));
      }
    }
    return out;
  }

  DocTable _table(XmlElement tbl) {
    final rows = <List<List<DocBlock>>>[];
    for (final tr in docChildren(tbl, 'tr')) {
      final cells = <List<DocBlock>>[];
      for (final tc in docChildren(tr, 'tc')) {
        cells.add(_blocks(tc));
      }
      rows.add(cells);
    }
    return DocTable(rows);
  }

  DocParagraph _paragraph(XmlElement p) {
    final pPr = docChild(p, 'pPr');
    final styleId = pPr == null ? null : docAttr(docChild(pPr, 'pStyle') ?? pPr, 'val');
    final styleName = _styleProp(styleId, (s) => s.name) ?? '';
    final style = switch (styleName) {
      'title' => 'title',
      'subtitle' => 'subtitle',
      final n when RegExp(r'^heading [1-6]$').hasMatch(n) => 'h${n.substring(8)}',
      _ => 'normal',
    };
    final align = switch ((pPr == null ? null : docAttr(docChild(pPr, 'jc') ?? pPr, 'val')) ??
        _styleProp(styleId, (s) => s.align)) {
      'center' => 'center',
      'right' || 'end' => 'right',
      'both' || 'distribute' => 'justify',
      _ => 'left',
    };
    final baseSize = _styleProp(styleId, (s) => s.size) ?? _defaultSize;
    final styleBold = _styleProp(styleId, (s) => s.bold) ?? false;
    final styleItalic = _styleProp(styleId, (s) => s.italic) ?? false;
    final styleColor = _styleProp(styleId, (s) => s.color);

    // List label.
    String? label;
    var level = 0;
    final numPr = pPr == null ? null : docChild(pPr, 'numPr');
    final numId = numPr != null ? docAttr(docChild(numPr, 'numId') ?? numPr, 'val') : _styleProp(styleId, (s) => s.numId);
    final ilvl = numPr != null ? docAttr(docChild(numPr, 'ilvl') ?? numPr, 'val') : _styleProp(styleId, (s) => s.ilvl);
    if (numId != null && numId != '0') {
      level = int.tryParse(ilvl ?? '') ?? 0;
      label = _listLabel(numId, level);
    }

    final runs = <DocRun>[];
    void addRuns(XmlElement parent, {bool link = false}) {
      for (final e in parent.childElements) {
        switch (e.name.local) {
          case 'r':
            runs.addAll(_run(e, link: link, styleBold: styleBold, styleItalic: styleItalic, styleColor: styleColor));
          case 'hyperlink':
            addRuns(e, link: true);
          case 'ins' || 'smartTag' || 'customXml' || 'fldSimple':
            addRuns(e, link: link);
          case 'sdt':
            final c = docChild(e, 'sdtContent');
            if (c != null) addRuns(c, link: link);
        }
      }
    }

    addRuns(p);
    final pageBreak = (pPr != null && _on(docChild(pPr, 'pageBreakBefore'))) ||
        docAll(p, 'br').any((b) => docAttr(b, 'type') == 'page');
    return DocParagraph(
      pid: _pids[p] ?? -1,
      runs: runs,
      style: style,
      align: align,
      listLabel: label,
      listLevel: level,
      pageBreakBefore: pageBreak,
      baseSize: baseSize,
    );
  }

  String _listLabel(String numId, int level) {
    final abs = _numToAbstract[numId];
    final (format, text) = _levels[abs]?[level] ?? ('bullet', '');
    if (format == 'bullet' || format == 'none') return const ['•', '◦', '▪'][level % 3];
    final counters = _counters.putIfAbsent(numId, () => List.filled(9, 0));
    counters[level]++;
    for (var i = level + 1; i < counters.length; i++) {
      counters[i] = 0;
    }
    String fmt(int n, String f) => switch (f) {
          'lowerLetter' => String.fromCharCode(96 + ((n - 1) % 26) + 1),
          'upperLetter' => String.fromCharCode(64 + ((n - 1) % 26) + 1),
          'lowerRoman' => _roman(n).toLowerCase(),
          'upperRoman' => _roman(n),
          _ => '$n',
        };
    if (text.isEmpty) return '${fmt(counters[level], format)}.';
    return text.replaceAllMapped(RegExp(r'%(\d)'), (m) {
      final l = int.parse(m[1]!) - 1;
      final lf = _levels[abs]?[l]?.$1 ?? 'decimal';
      return fmt(counters[l] == 0 ? 1 : counters[l], lf);
    });
  }

  static String _roman(int n) {
    const v = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    const s = ['M', 'CM', 'D', 'CD', 'C', 'XC', 'L', 'XL', 'X', 'IX', 'V', 'IV', 'I'];
    final b = StringBuffer();
    for (var i = 0; i < v.length; i++) {
      while (n >= v[i]) {
        b.write(s[i]);
        n -= v[i];
      }
    }
    return b.toString();
  }

  List<DocRun> _run(XmlElement r,
      {required bool link, required bool styleBold, required bool styleItalic, required int? styleColor}) {
    final rPr = docChild(r, 'rPr');
    bool flag(String name, bool fallback) {
      final e = rPr == null ? null : docChild(rPr, name);
      return e == null ? fallback : _on(e);
    }

    final sz = double.tryParse(rPr == null ? '' : docAttr(docChild(rPr, 'sz') ?? rPr, 'val') ?? '');
    final color = rPr == null ? null : _hexColor(docAttr(docChild(rPr, 'color') ?? rPr, 'val'));
    final hl = rPr == null ? null : docAttr(docChild(rPr, 'highlight') ?? rPr, 'val');
    final shd = rPr == null ? null : _hexColor(docAttr(docChild(rPr, 'shd') ?? rPr, 'fill'));
    final underline = rPr != null && docChild(rPr, 'u') != null && docAttr(docChild(rPr, 'u')!, 'val') != 'none';
    final vanish = rPr != null && _on(docChild(rPr, 'vanish'));
    if (vanish) return const [];

    final out = <DocRun>[];
    final text = runText(r);
    if (text.isNotEmpty) {
      out.add(DocRun(
        text,
        bold: flag('b', styleBold),
        italic: flag('i', styleItalic),
        underline: underline || link,
        strike: flag('strike', false) || flag('dstrike', false),
        size: sz == null ? null : sz / 2,
        color: link ? 0xFF1565C0 : (color ?? styleColor),
        highlight: hl != null ? _highlights[hl] : shd,
        link: link,
      ));
    }
    // Pictures: DrawingML <a:blip r:embed> or old VML <v:imagedata r:id>.
    for (final d in [...docAll(r, 'drawing'), ...docAll(r, 'pict')]) {
      final blip = docAll(d, 'blip').firstOrNull ?? docAll(d, 'imagedata').firstOrNull;
      final rid = blip == null ? null : (docAttr(blip, 'embed') ?? docAttr(blip, 'id'));
      final path = _rels[rid];
      final file = path == null ? null : zip.findFile(path);
      if (file == null) continue;
      final ext = docAll(d, 'extent').firstOrNull;
      final cx = double.tryParse(ext == null ? '' : docAttr(ext, 'cx') ?? '');
      final cy = double.tryParse(ext == null ? '' : docAttr(ext, 'cy') ?? '');
      out.add(DocRun('', image: Uint8List.fromList(file.content), imageWidth: cx == null ? null : cx / 9525,
          imageHeight: cy == null ? null : cy / 9525));
    }
    return out;
  }
}
