import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'sheet_reader.dart';

// ---- What the user typed ------------------------------------------------------------------

enum CellKind { empty, number, formula, text }

class CellInput {
  const CellInput(this.kind, [this.value = '']);
  final CellKind kind;

  /// number: the stored number ("1234.5"); formula: without "="; text: the text.
  final String value;
}

/// Turns typed text into a number / formula / text, like Excel does.
/// [format] is the cell's number format (a date cell turns "05/01/2025" into a date).
CellInput parseInput(String input, {String? format}) {
  final t = input.trim();
  if (t.isEmpty) return const CellInput(CellKind.empty);
  if (t.startsWith('=') && t.length > 1) return CellInput(CellKind.formula, t.substring(1));
  // Leading zeros / "+" (phone numbers, PIN codes) stay text.
  final keepText = RegExp(r'^0\d+$').hasMatch(t) || t.startsWith('+');
  if (!keepText) {
    final plain = t.replaceAll(',', '');
    final n = double.tryParse(plain);
    if (n != null && plain.isNotEmpty && !plain.contains(RegExp('[a-zA-Z]'))) return CellInput(CellKind.number, _num(n));
    if (plain.endsWith('%')) {
      final p = double.tryParse(plain.substring(0, plain.length - 1));
      if (p != null) return CellInput(CellKind.number, _num(p / 100));
    }
    if (format != null && _looksLikeDateFormat(format)) {
      final serial = _dateSerial(t);
      if (serial != null) return CellInput(CellKind.number, _num(serial));
    }
  }
  return CellInput(CellKind.text, input);
}

String _num(double n) => n == n.roundToDouble() && n.abs() < 1e15 ? n.toInt().toString() : n.toString();

bool _looksLikeDateFormat(String f) =>
    RegExp('[dy]', caseSensitive: false).hasMatch(f.replaceAll(RegExp(r'"[^"]*"|\[[^\]]*\]'), ''));

/// "05/01/2025" (day first), "5-1-2025", "2025-01-05" → Excel serial number.
double? _dateSerial(String t) {
  DateTime? d;
  final dmy = RegExp(r'^(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})$').firstMatch(t);
  final ymd = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(t);
  if (dmy != null) {
    var y = int.parse(dmy[3]!);
    if (y < 100) y += 2000;
    final m = int.parse(dmy[2]!), day = int.parse(dmy[1]!);
    if (m >= 1 && m <= 12 && day >= 1 && day <= 31) d = DateTime.utc(y, m, day);
  } else if (ymd != null) {
    d = DateTime.utc(int.parse(ymd[1]!), int.parse(ymd[2]!), int.parse(ymd[3]!));
  }
  if (d == null) return null;
  return d.difference(DateTime.utc(1899, 12, 30)).inDays.toDouble();
}

/// Text for the edit box: the formula, the stored number, or the text (dates as shown).
String editText(SheetData s, int row, int col) {
  final k = SheetData.key(row, col);
  final f = s.formulas[k];
  if (f != null) return '=$f';
  final raw = s.raw[k];
  final format = s.formats[k];
  if (raw != null && !(format != null && _looksLikeDateFormat(format))) return raw;
  return s.cell(row, col) ?? '';
}

/// Puts typed text into the sheet shown on screen (the file changes on save).
void setCell(SheetData s, int row, int col, String input, {required bool csv}) {
  final k = SheetData.key(row, col);
  s.formulas.remove(k);
  s.raw.remove(k);
  s.numeric.remove(k);
  final rowCells = s.cells[row] ??= {};
  if (csv) {
    if (input.isEmpty) {
      rowCells.remove(col);
    } else {
      rowCells[col] = input;
      if (double.tryParse(input.replaceAll(',', '')) != null) s.numeric.add(k);
    }
  } else {
    final v = parseInput(input, format: s.formats[k]);
    switch (v.kind) {
      case CellKind.empty:
        rowCells.remove(col);
      case CellKind.number:
        s.raw[k] = v.value;
        s.numeric.add(k);
        rowCells[col] = formatNumber(double.parse(v.value), s.formats[k] ?? 'General');
      case CellKind.formula:
        s.formulas[k] = v.value;
        rowCells[col] = '=${v.value}'; // worked out by Excel / Sheets when the file is opened there
      case CellKind.text:
        rowCells[col] = v.value;
    }
  }
  if (rowCells.isEmpty) s.cells.remove(row);
  s.rowCount = math.max(s.rowCount, row + 1);
  s.colCount = math.max(s.colCount, col + 1);
}

// ---- CSV ----------------------------------------------------------------------------------

Uint8List saveCsv(SheetData s, String separator) {
  String quote(String v) =>
      v.contains(separator) || v.contains('"') || v.contains('\n') || v.contains('\r') ? '"${v.replaceAll('"', '""')}"' : v;
  final b = StringBuffer('﻿'); // so Excel reads non-English text correctly
  for (var r = 0; r < s.rowCount; r++) {
    final row = s.cells[r];
    var last = -1;
    if (row != null) {
      for (final c in row.keys) {
        last = math.max(last, c);
      }
    }
    b.write(List.generate(last + 1, (c) => quote(row?[c] ?? '')).join(separator));
    b.write('\r\n');
  }
  return Uint8List.fromList(utf8.encode(b.toString()));
}

// ---- XLSX ---------------------------------------------------------------------------------

const _mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const _relNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _worksheetType = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet';
const _worksheetContent = 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml';

/// A new, empty workbook with one sheet ("New spreadsheet").
Uint8List newWorkbook() {
  final files = {
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="$_worksheetContent"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '</Types>',
    '_rels/.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="$_relNs/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>',
    'xl/workbook.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="$_mainNs" xmlns:r="$_relNs">'
        '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>'
        '<calcPr fullCalcOnLoad="1"/>'
        '</workbook>',
    'xl/_rels/workbook.xml.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="$_worksheetType" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="$_relNs/styles" Target="styles.xml"/>'
        '</Relationships>',
    'xl/styles.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="$_mainNs">'
        '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>'
        '</styleSheet>',
    'xl/worksheets/sheet1.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="$_mainNs" xmlns:r="$_relNs"><sheetData/></worksheet>',
  };
  final archive = Archive();
  files.forEach((name, text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Iterable<XmlElement> _all(XmlNode n, String local) => n.descendantElements.where((e) => e.name.local == local);
Iterable<XmlElement> _children(XmlNode n, String local) => n.childElements.where((e) => e.name.local == local);
XmlElement? _child(XmlNode n, String local) => _children(n, local).firstOrNull;
String? _attr(XmlElement e, String local) => e.attributes.where((a) => a.name.local == local).firstOrNull?.value;

/// Writes the edits into the original .xlsx, keeping everything else (styles, charts,
/// other sheets). [edits]: per sheet, cell key → what the user typed. Sheets without a
/// [SheetData.path] are new and get added. Excel / Sheets recalculate formulas on open.
Uint8List saveXlsx(Uint8List original, Workbook book, Map<SheetData, Map<int, String>> edits) {
  final zip = ZipDecoder().decodeBytes(original);
  final changed = <String, String>{};
  final removed = <String>{};
  String? text(String path) {
    if (changed.containsKey(path)) return changed[path];
    final f = zip.findFile(path);
    return f == null ? null : utf8.decode(f.content, allowMalformed: true);
  }

  final workbook = XmlDocument.parse(text('xl/workbook.xml')!);
  final rels = XmlDocument.parse(text('xl/_rels/workbook.xml.rels') ??
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>');
  final types = XmlDocument.parse(text('[Content_Types].xml') ??
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>');

  // New sheets: a worksheet part, a relationship, a content type and a <sheet> entry.
  for (final s in book.sheets.where((s) => s.path == null)) {
    var n = 1;
    while (zip.findFile('xl/worksheets/sheet$n.xml') != null || changed.containsKey('xl/worksheets/sheet$n.xml')) {
      n++;
    }
    final path = 'xl/worksheets/sheet$n.xml';
    final sheetDoc = XmlDocument.parse('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="$_mainNs" xmlns:r="$_relNs"><sheetData/></worksheet>');
    _applyEdits(sheetDoc, edits[s] ?? const {}, s.formats);
    changed[path] = sheetDoc.toXmlString();

    var rid = 1;
    final usedIds = _all(rels, 'Relationship').map((r) => _attr(r, 'Id')).toSet();
    while (usedIds.contains('rId$rid')) {
      rid++;
    }
    rels.rootElement.children.add(XmlElement(XmlName.parts('Relationship'), [
      XmlAttribute(XmlName.parts('Id'), 'rId$rid'),
      XmlAttribute(XmlName.parts('Type'), _worksheetType),
      XmlAttribute(XmlName.parts('Target'), 'worksheets/sheet$n.xml'),
    ]));
    types.rootElement.children.add(XmlElement(XmlName.parts('Override'), [
      XmlAttribute(XmlName.parts('PartName'), '/$path'),
      XmlAttribute(XmlName.parts('ContentType'), _worksheetContent),
    ]));
    final sheets = _all(workbook, 'sheets').first;
    final maxId = _children(sheets, 'sheet').map((e) => int.tryParse(_attr(e, 'sheetId') ?? '') ?? 0).fold(0, math.max);
    final rPrefix = _relPrefix(workbook.rootElement);
    sheets.children.add(XmlElement(XmlName.parts('sheet', prefix: sheets.name.prefix), [
      XmlAttribute(XmlName.parts('name'), s.name),
      XmlAttribute(XmlName.parts('sheetId'), '${maxId + 1}'),
      XmlAttribute(XmlName.parts('id', prefix: rPrefix), 'rId$rid'),
    ]));
  }

  // Edited sheets.
  for (final s in book.sheets.where((s) => s.path != null && (edits[s]?.isNotEmpty ?? false))) {
    final xml = text(s.path!);
    if (xml == null) continue;
    final doc = XmlDocument.parse(xml);
    _applyEdits(doc, edits[s]!, s.formats);
    changed[s.path!] = doc.toXmlString();
  }

  // Formulas changed: drop the calculation chain (Excel would call the file damaged
  // if it lists cells that aren't formulas any more) and recalculate on open.
  removed.add('xl/calcChain.xml');
  for (final r in _all(rels, 'Relationship').toList()) {
    if ((_attr(r, 'Target') ?? '').endsWith('calcChain.xml')) r.remove();
  }
  for (final o in _all(types, 'Override').toList()) {
    if (_attr(o, 'PartName') == '/xl/calcChain.xml') o.remove();
  }
  _recalculateOnOpen(workbook);

  changed['xl/workbook.xml'] = workbook.toXmlString();
  changed['xl/_rels/workbook.xml.rels'] = rels.toXmlString();
  changed['[Content_Types].xml'] = types.toXmlString();

  final out = Archive();
  for (final f in zip.files) {
    if (removed.contains(f.name) || changed.containsKey(f.name)) continue;
    out.addFile(f);
  }
  changed.forEach((name, xml) {
    final bytes = utf8.encode(xml);
    out.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(out));
}

/// Prefix the workbook uses for the relationships namespace ("r"), declaring it if missing.
String _relPrefix(XmlElement root) {
  for (final a in root.attributes) {
    if (a.name.prefix == 'xmlns' && a.value == _relNs) return a.name.local;
  }
  root.attributes.add(XmlAttribute(XmlName.parts('r', prefix: 'xmlns'), _relNs));
  return 'r';
}

void _recalculateOnOpen(XmlDocument workbook) {
  final root = workbook.rootElement;
  var calc = _child(root, 'calcPr');
  if (calc == null) {
    calc = XmlElement(XmlName.parts('calcPr', prefix: root.name.prefix));
    // Schema order: … sheets, functionGroups, externalReferences, definedNames, calcPr …
    XmlElement? after;
    for (final name in ['sheets', 'functionGroups', 'externalReferences', 'definedNames']) {
      after = _child(root, name) ?? after;
    }
    if (after != null) {
      root.children.insert(root.children.indexOf(after) + 1, calc);
    } else {
      root.children.add(calc);
    }
  }
  calc.setAttribute('fullCalcOnLoad', '1');
}

/// Applies typed values to a worksheet XML (rows and cells kept in order).
void _applyEdits(XmlDocument doc, Map<int, String> edits, Map<int, String> formats) {
  final ws = doc.rootElement;
  final prefix = ws.name.prefix;
  XmlName name(String local) => XmlName.parts(local, prefix: prefix);
  var sheetData = _child(ws, 'sheetData');
  if (sheetData == null) {
    sheetData = XmlElement(name('sheetData'));
    ws.children.add(sheetData);
  }
  _child(ws, 'dimension')?.remove(); // optional; would be out of date

  final keys = edits.keys.toList()..sort();
  for (final k in keys) {
    final row = k ~/ 16384, col = k % 16384;
    final ref = '${columnName(col)}${row + 1}';
    final input = parseInput(edits[k]!, format: formats[k]);

    // Find or make the <row>.
    XmlElement? rowEl;
    XmlElement? rowAfter;
    var nextRow = 1;
    for (final r in _children(sheetData, 'row')) {
      final n = int.tryParse(_attr(r, 'r') ?? '') ?? nextRow;
      nextRow = n + 1;
      if (n == row + 1) rowEl = r;
      if (n > row + 1) {
        rowAfter = r;
        break;
      }
    }
    if (rowEl == null) {
      if (input.kind == CellKind.empty) continue;
      rowEl = XmlElement(name('row'), [XmlAttribute(XmlName.parts('r'), '${row + 1}')]);
      if (rowAfter != null) {
        sheetData.children.insert(sheetData.children.indexOf(rowAfter), rowEl);
      } else {
        sheetData.children.add(rowEl);
      }
    }
    rowEl.removeAttribute('spans'); // a hint; may no longer cover the cells

    // Find or make the <c>.
    XmlElement? cell;
    XmlElement? cellAfter;
    var nextCol = 0;
    for (final c in _children(rowEl, 'c')) {
      final m = RegExp(r'^([A-Za-z]+)').firstMatch(_attr(c, 'r') ?? '');
      var n = nextCol;
      if (m != null) {
        n = 0;
        for (final ch in m[1]!.toUpperCase().codeUnits) {
          n = n * 26 + (ch - 64);
        }
        n -= 1;
      }
      nextCol = n + 1;
      if (n == col) cell = c;
      if (n > col) {
        cellAfter = c;
        break;
      }
    }

    if (input.kind == CellKind.empty) {
      if (cell == null) continue;
      cell.children.clear();
      cell.removeAttribute('t');
      if (_attr(cell, 's') == null) cell.remove(); // nothing left to keep
      continue;
    }
    if (cell == null) {
      cell = XmlElement(name('c'), [XmlAttribute(XmlName.parts('r'), ref)]);
      if (cellAfter != null) {
        rowEl.children.insert(rowEl.children.indexOf(cellAfter), cell);
      } else {
        rowEl.children.add(cell);
      }
    }
    cell.children.clear();
    cell.removeAttribute('t');
    cell.removeAttribute('cm'); // array/dynamic formula metadata no longer applies
    switch (input.kind) {
      case CellKind.number:
        cell.children.add(XmlElement(name('v'), [], [XmlText(input.value)]));
      case CellKind.formula:
        cell.children.add(XmlElement(name('f'), [], [XmlText(input.value)]));
      case CellKind.text:
        cell.setAttribute('t', 'inlineStr');
        cell.children.add(XmlElement(name('is'), [], [
          XmlElement(name('t'), [XmlAttribute(XmlName.parts('space', prefix: 'xml'), 'preserve')], [XmlText(input.value)]),
        ]));
      case CellKind.empty:
        break;
    }
  }
}

/// [saveXlsx] on a background isolate. Top-level on purpose: a closure created inside a
/// widget's State method also captures the State, which can't be sent to an isolate.
Future<Uint8List> saveXlsxInBackground(Uint8List original, Workbook book, Map<SheetData, Map<int, String>> edits) =>
    Isolate.run(() => saveXlsx(original, book, edits));
