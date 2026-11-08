import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'doc_reader.dart';

/// Changes to one existing paragraph (null = unchanged).
class ParaEdit {
  String? text;
  String? style; // normal, title, subtitle, h1, h2, h3
  String? align; // left, center, right, justify
  bool? bold, italic, underline; // whole paragraph
  bool delete = false;

  bool get isEmpty =>
      text == null && style == null && align == null && bold == null && italic == null && underline == null && !delete;
}

/// A paragraph added in the editor, next to an existing one (formatting copied from it).
class NewParagraph {
  NewParagraph({
    required this.anchorPid,
    required this.text,
    this.before = false,
    this.runFormatAt,
    this.style,
    this.align,
    this.bold,
    this.italic,
    this.underline,
  });

  /// Existing paragraph it goes after (or [before]); -1 = start of the document.
  final int anchorPid;
  final bool before;
  final String text;

  /// Copy the text formatting of the anchor at this text position (Enter splits a
  /// paragraph: the new one continues the formatting at the cursor). Null = last run.
  final int? runFormatAt;
  final String? style, align;
  final bool? bold, italic, underline;
}

class DocEdits {
  final paras = <int, ParaEdit>{};

  /// In document order; several with the same anchor go in this order.
  final inserted = <NewParagraph>[];

  ParaEdit of(int pid) => paras.putIfAbsent(pid, ParaEdit.new);
  bool get isEmpty => inserted.isEmpty && paras.values.every((e) => e.isEmpty);
}

// ---- Schema order (Word reports "unreadable content" when it's wrong) ----------------------

const _rPrOrder = [
  'rStyle', 'rFonts', 'b', 'bCs', 'i', 'iCs', 'caps', 'smallCaps', 'strike', 'dstrike', 'outline', 'shadow',
  'emboss', 'imprint', 'noProof', 'snapToGrid', 'vanish', 'webHidden', 'color', 'spacing', 'w', 'kern',
  'position', 'sz', 'szCs', 'highlight', 'u', 'effect', 'bdr', 'shd', 'fitText', 'vertAlign', 'rtl', 'cs', 'em',
  'lang', 'eastAsianLayout', 'specVanish', 'oMath', 'rPrChange',
];

const _pPrOrder = [
  'pStyle', 'keepNext', 'keepLines', 'pageBreakBefore', 'framePr', 'widowControl', 'numPr',
  'suppressLineNumbers', 'pBdr', 'shd', 'tabs', 'suppressAutoHyphens', 'kinsoku', 'wordWrap', 'overflowPunct',
  'topLinePunct', 'autoSpaceDE', 'autoSpaceDN', 'bidi', 'adjustRightInd', 'snapToGrid', 'spacing', 'ind',
  'contextualSpacing', 'mirrorIndents', 'suppressOverlap', 'jc', 'textDirection', 'textAlignment',
  'textboxTightWrap', 'outlineLvl', 'divId', 'cnfStyle', 'rPr', 'sectPr', 'pPrChange',
];

/// Puts [child] into [parent] at its schema position (replacing one with the same name).
void _setOrdered(XmlElement parent, XmlElement child, List<String> order) {
  for (final old in docChildren(parent, child.name.local).toList()) {
    old.remove();
  }
  final idx = order.indexOf(child.name.local);
  for (var i = 0; i < parent.children.length; i++) {
    final n = parent.children[i];
    if (n is XmlElement && order.indexOf(n.name.local) > idx) {
      parent.children.insert(i, child);
      return;
    }
  }
  parent.children.add(child);
}

void _removeChild(XmlElement parent, String local) {
  for (final old in docChildren(parent, local).toList()) {
    old.remove();
  }
}

XmlElement _el(String? prefix, String local, [Map<String, String> attrs = const {}, List<XmlNode> children = const []]) =>
    XmlElement(
      XmlName.parts(local, prefix: prefix),
      [for (final a in attrs.entries) XmlAttribute(XmlName.parts(a.key, prefix: prefix), a.value)],
      children,
    );

/// The first child [local] of [parent], created (at its schema position) if missing.
XmlElement _ensure(XmlElement parent, String local, List<String> order, {bool first = false}) {
  final found = docChild(parent, local);
  if (found != null) return found;
  final e = _el(parent.name.prefix, local);
  if (first) {
    parent.children.insert(0, e);
  } else {
    _setOrdered(parent, e, order);
  }
  return e;
}

// ---- Runs ---------------------------------------------------------------------------------

/// This paragraph's own text runs (not those of a text box inside it).
List<XmlElement> _ownTextRuns(XmlElement p) => docAll(p, 'r')
    .where((r) => r.ancestorElements.firstWhere((a) => a.name.local == 'p') == p && isTextRun(r))
    .toList();

/// Replaces a run's text, keeping its formatting (\t → tab, \n → line break).
void _writeRunText(XmlElement r, String text) {
  final prefix = r.name.prefix;
  r.children.removeWhere((n) => !(n is XmlElement && n.name.local == 'rPr'));
  final parts = RegExp(r'[^\t\n]+|\t|\n').allMatches(text).map((m) => m[0]!);
  for (final part in parts) {
    if (part == '\t') {
      r.children.add(_el(prefix, 'tab'));
    } else if (part == '\n') {
      r.children.add(_el(prefix, 'br'));
    } else {
      r.children.add(XmlElement(XmlName.parts('t', prefix: prefix),
          [XmlAttribute(XmlName.parts('space', prefix: 'xml'), 'preserve')], [XmlText(part)]));
    }
  }
}

/// Sets the paragraph's text with the smallest change, so formatting of the
/// untouched words stays: only the changed part is replaced, inside the run where
/// the change starts.
void setParagraphText(XmlElement p, String newText) {
  var runs = _ownTextRuns(p);
  final texts = runs.map(runText).toList();
  final old = texts.join();
  if (old == newText) return;
  if (runs.isEmpty) {
    final r = _el(p.name.prefix, 'r');
    final markProps = docChild(docChild(p, 'pPr') ?? p, 'rPr');
    if (markProps != null) r.children.add(_copyRunProps(markProps));
    p.children.add(r);
    runs = [r];
    texts.add('');
  }

  // Which run every old character is in.
  final runOfOld = <int>[];
  for (var j = 0; j < texts.length; j++) {
    runOfOld.addAll(List.filled(texts[j].length, j));
  }

  // Each new character goes to a run: kept characters stay in their run; typed
  // ones take the run of the character before them (like Word), or the first run.
  final kept = _keptChars(old, newText); // new index → old index (or -1)
  final buffers = List.generate(runs.length, (_) => StringBuffer());
  var current = 0;
  for (var i = 0; i < newText.length; i++) {
    final o = kept[i];
    if (o >= 0) current = runOfOld[o];
    buffers[current].write(newText[i]);
  }

  for (var j = 0; j < runs.length; j++) {
    final nt = buffers[j].toString();
    if (nt == texts[j]) continue;
    if (nt.isEmpty && runs.length > 1) {
      runs[j].remove();
    } else {
      _writeRunText(runs[j], nt);
    }
  }
}

/// For each character of [b]: the index of the same character in [a] when it was kept
/// (longest common subsequence), else -1. Long texts: common start and end only.
List<int> _keptChars(String a, String b) {
  final result = List.filled(b.length, -1);
  var pre = 0;
  while (pre < a.length && pre < b.length && a[pre] == b[pre]) {
    result[pre] = pre;
    pre++;
  }
  var suf = 0;
  while (suf < a.length - pre && suf < b.length - pre && a[a.length - 1 - suf] == b[b.length - 1 - suf]) {
    result[b.length - 1 - suf] = a.length - 1 - suf;
    suf++;
  }
  final ma = a.substring(pre, a.length - suf), mb = b.substring(pre, b.length - suf);
  if (ma.isEmpty || mb.isEmpty || ma.length * mb.length > 4000000) return result;

  // LCS table on the middle part.
  final n = ma.length, m = mb.length;
  final dp = List.generate(n + 1, (_) => Uint16List(m + 1));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = ma[i] == mb[j] ? dp[i + 1][j + 1] + 1 : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (ma[i] == mb[j]) {
      result[pre + j] = pre + i;
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return result;
}

/// Run formatting from a paragraph mark's rPr (some of its children only belong there).
XmlElement _copyRunProps(XmlElement rPr) {
  final c = rPr.copy();
  c.children.removeWhere((n) => n is XmlElement && const {'ins', 'del', 'moveFrom', 'moveTo', 'rPrChange'}.contains(n.name.local));
  return c;
}

void _setRunFlag(XmlElement r, String flag, bool on) {
  final rPr = _ensure(r, 'rPr', const ['rPr'], first: true);
  final prefix = r.name.prefix;
  if (flag == 'u') {
    _setOrdered(rPr, _el(prefix, 'u', {'val': on ? 'single' : 'none'}), _rPrOrder);
  } else {
    _setOrdered(rPr, on ? _el(prefix, flag) : _el(prefix, flag, {'val': '0'}), _rPrOrder);
    final cs = '${flag}Cs';
    if (_rPrOrder.contains(cs)) {
      _setOrdered(rPr, on ? _el(prefix, cs) : _el(prefix, cs, {'val': '0'}), _rPrOrder);
    }
  }
}

void _setParagraphFlags(XmlElement p, {bool? bold, bool? italic, bool? underline}) {
  for (final r in _ownTextRuns(p)) {
    if (bold != null) _setRunFlag(r, 'b', bold);
    if (italic != null) _setRunFlag(r, 'i', italic);
    if (underline != null) _setRunFlag(r, 'u', underline);
  }
}

// ---- Paragraph style / alignment ---------------------------------------------------------

const _styleNames = {'title': 'title', 'subtitle': 'subtitle', 'h1': 'heading 1', 'h2': 'heading 2', 'h3': 'heading 3'};
const _styleIds = {'title': 'Title', 'subtitle': 'Subtitle', 'h1': 'Heading1', 'h2': 'Heading2', 'h3': 'Heading3'};

/// Style definitions added to styles.xml when the document doesn't have them yet.
String _styleXml(String key) => switch (key) {
      'title' => '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>'
          '<w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="120"/></w:pPr>'
          '<w:rPr><w:sz w:val="52"/><w:szCs w:val="52"/></w:rPr></w:style>',
      'subtitle' => '<w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/>'
          '<w:next w:val="Normal"/><w:qFormat/><w:rPr><w:i/><w:color w:val="595959"/><w:sz w:val="30"/>'
          '<w:szCs w:val="30"/></w:rPr></w:style>',
      _ => () {
          final n = key.substring(1);
          final size = {'1': 32, '2': 28, '3': 24}[n]!;
          return '<w:style w:type="paragraph" w:styleId="Heading$n"><w:name w:val="heading $n"/>'
              '<w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>'
              '<w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="${int.parse(n) - 1}"/></w:pPr>'
              '<w:rPr><w:b/><w:bCs/><w:sz w:val="$size"/><w:szCs w:val="$size"/></w:rPr></w:style>';
        }(),
    };

class _StyleSheet {
  _StyleSheet(this.doc);
  final XmlDocument? doc;
  bool changed = false;

  /// The styleId for [key] (finds localized ids by the style's name, adds it if missing).
  String idFor(String key) {
    final want = _styleNames[key]!;
    final d = doc;
    if (d != null) {
      for (final s in docAll(d, 'style')) {
        if (docAttr(s, 'type') == 'paragraph' && docAttr(docChild(s, 'name') ?? s, 'val')?.toLowerCase() == want) {
          return docAttr(s, 'styleId')!;
        }
      }
      final frag = XmlDocumentFragment.parse(
          '<x xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">${_styleXml(key)}</x>');
      final style = frag.firstElementChild!.firstElementChild!.copy();
      d.rootElement.children.add(style);
      changed = true;
    }
    return _styleIds[key]!;
  }
}

void _setStyle(XmlElement p, String style, _StyleSheet sheet) {
  final pPr = _ensure(p, 'pPr', const ['pPr'], first: true);
  if (style == 'normal') {
    _removeChild(pPr, 'pStyle');
  } else {
    _setOrdered(pPr, _el(p.name.prefix, 'pStyle', {'val': sheet.idFor(style)}), _pPrOrder);
  }
}

void _setAlign(XmlElement p, String align) {
  final pPr = _ensure(p, 'pPr', const ['pPr'], first: true);
  final v = switch (align) { 'center' => 'center', 'right' => 'right', 'justify' => 'both', _ => 'left' };
  _setOrdered(pPr, _el(p.name.prefix, 'jc', {'val': v}), _pPrOrder);
}

/// A new paragraph shaped like [anchor]: same paragraph settings (list, spacing) and
/// the text formatting at [runFormatAt].
XmlElement _paragraphLike(XmlElement anchor, String text, int? runFormatAt) {
  final prefix = anchor.name.prefix;
  final p = _el(prefix, 'p');
  final pPr = docChild(anchor, 'pPr');
  if (pPr != null) {
    final c = pPr.copy();
    // These belong to the anchor only (a section end must not be duplicated).
    c.children.removeWhere((n) => n is XmlElement && const {'sectPr', 'pageBreakBefore', 'pPrChange'}.contains(n.name.local));
    p.children.add(c);
  }
  final runs = _ownTextRuns(anchor);
  XmlElement? source;
  if (runs.isNotEmpty) {
    source = runs.last;
    if (runFormatAt != null) {
      var pos = 0;
      for (final r in runs) {
        final len = runText(r).length;
        if (runFormatAt <= pos + len) {
          source = r;
          break;
        }
        pos += len;
      }
    }
  }
  final r = _el(prefix, 'r');
  final rPr = source == null ? docChild(pPr ?? anchor, 'rPr') : docChild(source, 'rPr');
  if (rPr != null) r.children.add(_copyRunProps(rPr));
  _writeRunText(r, text);
  if (text.isNotEmpty) p.children.add(r);
  return p;
}

// ---- Saving -------------------------------------------------------------------------------

/// Writes [edits] into the original .docx; everything else is kept byte for byte.
Uint8List saveDocx(Uint8List original, DocEdits edits) {
  final zip = ZipDecoder().decodeBytes(original);
  String? text(String path) {
    final f = zip.findFile(path);
    return f == null ? null : utf8.decode(f.content, allowMalformed: true);
  }

  final doc = XmlDocument.parse(text('word/document.xml')!);
  final stylesXml = text('word/styles.xml');
  final sheet = _StyleSheet(stylesXml == null ? null : XmlDocument.parse(stylesXml));
  final ps = bodyParagraphs(doc);

  // 1. New paragraphs (anchors still exist: deletions come last).
  final lastInserted = <String, XmlElement>{};
  for (final n in edits.inserted) {
    XmlElement newP;
    if (n.anchorPid >= 0 && n.anchorPid < ps.length) {
      final anchor = ps[n.anchorPid];
      newP = _paragraphLike(anchor, n.text, n.runFormatAt);
      final key = '${n.anchorPid}/${n.before}';
      final after = lastInserted[key];
      final parent = anchor.parent!;
      if (after != null) {
        parent.children.insert(parent.children.indexOf(after) + 1, newP);
      } else if (n.before) {
        parent.children.insert(parent.children.indexOf(anchor), newP);
      } else {
        parent.children.insert(parent.children.indexOf(anchor) + 1, newP);
      }
      lastInserted[key] = newP;
    } else {
      // Empty document: at the start of the body (before its section settings).
      final body = docAll(doc, 'body').first;
      newP = _el(body.name.prefix, 'p');
      final r = _el(body.name.prefix, 'r');
      _writeRunText(r, n.text);
      if (n.text.isNotEmpty) newP.children.add(r);
      final after = lastInserted['start'];
      final idx = after != null ? body.children.indexOf(after) + 1 : 0;
      body.children.insert(idx, newP);
      lastInserted['start'] = newP;
    }
    if (n.style != null) _setStyle(newP, n.style!, sheet);
    if (n.align != null) _setAlign(newP, n.align!);
    _setParagraphFlags(newP, bold: n.bold, italic: n.italic, underline: n.underline);
  }

  // 2. Changed paragraphs.
  for (final e in edits.paras.entries) {
    if (e.key < 0 || e.key >= ps.length || e.value.delete) continue;
    final p = ps[e.key];
    final ed = e.value;
    if (ed.text != null) setParagraphText(p, ed.text!);
    if (ed.style != null) _setStyle(p, ed.style!, sheet);
    if (ed.align != null) _setAlign(p, ed.align!);
    _setParagraphFlags(p, bold: ed.bold, italic: ed.italic, underline: ed.underline);
  }

  // 3. Deleted paragraphs (a table cell keeps at least one, emptied).
  for (final e in edits.paras.entries.where((e) => e.value.delete)) {
    if (e.key < 0 || e.key >= ps.length) continue;
    final p = ps[e.key];
    final parent = p.parent;
    final siblings = parent == null ? 0 : docChildren(parent, 'p').length;
    if (parent is XmlElement && parent.name.local == 'tc' && siblings <= 1) {
      setParagraphText(p, '');
    } else if (docChild(docChild(p, 'pPr') ?? p, 'sectPr') != null) {
      setParagraphText(p, ''); // carries a section's page settings: keep it, empty
    } else {
      p.remove();
    }
  }

  final changed = <String, String>{'word/document.xml': doc.toXmlString()};
  if (sheet.changed) changed['word/styles.xml'] = sheet.doc!.toXmlString();
  final out = Archive();
  for (final f in zip.files) {
    if (!changed.containsKey(f.name)) out.addFile(f);
  }
  changed.forEach((name, xml) {
    final bytes = utf8.encode(xml);
    out.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(out));
}

/// Plain text file from the editor's paragraphs.
Uint8List saveText(List<String> lines) => Uint8List.fromList(utf8.encode('${lines.join('\n')}\n'));

/// A new, empty Word document (A4, Normal + Title + Heading 1–3 styles).
Uint8List newDocument() {
  const w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  const r = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  final files = {
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        '</Types>',
    '_rels/.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="$r/officeDocument" Target="word/document.xml"/>'
        '</Relationships>',
    'word/_rels/document.xml.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="$r/styles" Target="styles.xml"/>'
        '</Relationships>',
    'word/document.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="$w" xmlns:r="$r"><w:body><w:p/>'
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/>'
        '</w:sectPr></w:body></w:document>',
    'word/styles.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:styles xmlns:w="$w">'
        '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/>'
        '<w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault>'
        '<w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
        '${_styleXml('title')}${_styleXml('subtitle')}${_styleXml('h1')}${_styleXml('h2')}${_styleXml('h3')}'
        '</w:styles>',
  };
  final archive = Archive();
  files.forEach((name, t) {
    final bytes = utf8.encode(t);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
