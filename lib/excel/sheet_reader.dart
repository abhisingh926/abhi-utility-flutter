import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Cells that span several rows / columns (0-based, data coordinates).
class SheetMerge {
  const SheetMerge(this.row, this.col, this.rowSpan, this.colSpan);
  final int row, col, rowSpan, colSpan;
}

/// One worksheet, as text ready to show.
class SheetData {
  SheetData({
    required this.name,
    required this.cells,
    required this.rowCount,
    required this.colCount,
    this.colWidths = const {},
    this.merges = const [],
    this.bold = const {},
    this.numeric = const {},
  });

  final String name;

  /// row → column → shown text (0-based).
  final Map<int, Map<int, String>> cells;
  final int rowCount, colCount;

  /// Column widths in Excel units (≈ characters).
  final Map<int, double> colWidths;
  final List<SheetMerge> merges;

  /// [key]s of bold cells and of numbers (shown right-aligned).
  final Set<int> bold, numeric;

  static int key(int row, int col) => row * 16384 + col; // Excel has at most 16384 columns

  String? cell(int row, int col) => cells[row]?[col];
  bool get isEmpty => cells.isEmpty;
}

class Workbook {
  const Workbook(this.sheets);
  final List<SheetData> sheets;
}

class SheetFormatException implements Exception {
  const SheetFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads an .xlsx / .xlsm / .csv file in a background isolate (big sheets don't freeze the UI).
Future<Workbook> readWorkbook(Uint8List bytes, String fileName) =>
    Isolate.run(() => parseWorkbook(bytes, fileName));

/// Same as [readWorkbook], on the calling isolate (used by tests).
Workbook parseWorkbook(Uint8List bytes, String fileName) {
  if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) return _Xlsx(bytes).read(); // "PK": zip
  if (bytes.length >= 4 && bytes[0] == 0xD0 && bytes[1] == 0xCF && bytes[2] == 0x11 && bytes[3] == 0xE0) {
    throw const SheetFormatException(
        "This is the old Excel format (.xls), which can't be opened here yet. "
        'Open it in Google Sheets or Excel and save it as .xlsx.');
  }
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.xlsx') || lower.endsWith('.xlsm')) {
    throw const SheetFormatException('This file is damaged or not really an Excel file.');
  }
  return Workbook([_parseCsv(bytes, fileName)]);
}

// ---- Helpers ----------------------------------------------------------------------------

/// Elements by local name, whatever namespace prefix the file uses ("x:sheet" or "sheet").
Iterable<XmlElement> _all(XmlNode node, String local) =>
    node.descendantElements.where((e) => e.name.local == local);

Iterable<XmlElement> _children(XmlNode node, String local) =>
    node.childElements.where((e) => e.name.local == local);

XmlElement? _child(XmlNode node, String local) {
  for (final e in node.childElements) {
    if (e.name.local == local) return e;
  }
  return null;
}

String? _attr(XmlElement e, String local) {
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

/// "C12" → (row 11, col 2).
(int, int)? _ref(String ref) {
  var col = 0, i = 0;
  while (i < ref.length) {
    final c = ref.codeUnitAt(i) | 0x20; // lower case
    if (c < 0x61 || c > 0x7A) break;
    col = col * 26 + (c - 0x60);
    i++;
  }
  final row = int.tryParse(ref.substring(i));
  if (col == 0 || row == null) return null;
  return (row - 1, col - 1);
}

/// Column letters: 0 → A, 26 → AA.
String columnName(int col) {
  var n = col + 1;
  var s = '';
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

// ---- XLSX ---------------------------------------------------------------------------------

class _Xlsx {
  _Xlsx(Uint8List bytes) : zip = ZipDecoder().decodeBytes(bytes);
  final Archive zip;

  String? _text(String path) {
    final f = zip.findFile(path);
    return f == null ? null : utf8.decode(f.content, allowMalformed: true);
  }

  Workbook read() {
    final wbXml = _text('xl/workbook.xml');
    if (wbXml == null) throw const SheetFormatException('This is not an Excel workbook.');
    final wb = XmlDocument.parse(wbXml);

    final rels = <String, String>{};
    final relsXml = _text('xl/_rels/workbook.xml.rels');
    if (relsXml != null) {
      for (final r in _all(XmlDocument.parse(relsXml), 'Relationship')) {
        var target = _attr(r, 'Target') ?? '';
        target = target.startsWith('/') ? target.substring(1) : 'xl/${target.replaceFirst(RegExp(r'^\./'), '')}';
        rels[_attr(r, 'Id') ?? ''] = target;
      }
    }

    final pr = _all(wb, 'workbookPr').firstOrNull;
    final date1904 = pr != null && ['1', 'true'].contains(_attr(pr, 'date1904'));
    final shared = _sharedStrings(_text('xl/sharedStrings.xml'));
    final styles = _Styles.parse(_text('xl/styles.xml'));

    final sheets = <SheetData>[];
    var index = 0;
    for (final s in _all(wb, 'sheet')) {
      index++;
      final state = _attr(s, 'state');
      if (state == 'hidden' || state == 'veryHidden') continue;
      final name = _attr(s, 'name') ?? 'Sheet $index';
      final path = rels[_attr(s, 'id')] ?? 'xl/worksheets/sheet$index.xml';
      final xml = _text(path);
      if (xml == null) continue; // a chart sheet, not a grid
      sheets.add(_sheet(name, xml, shared, styles, date1904));
    }
    if (sheets.isEmpty) throw const SheetFormatException('This workbook has no sheets to show.');
    return Workbook(sheets);
  }

  static List<String> _sharedStrings(String? xml) {
    if (xml == null) return const [];
    final out = <String>[];
    for (final si in _all(XmlDocument.parse(xml), 'si')) {
      final b = StringBuffer();
      for (final t in _all(si, 't')) {
        // Skip phonetic (furigana) runs.
        if (t.ancestorElements.any((a) => a.name.local == 'rPh')) continue;
        b.write(t.innerText);
      }
      out.add(b.toString());
    }
    return out;
  }

  static SheetData _sheet(String name, String xml, List<String> shared, _Styles styles, bool date1904) {
    final doc = XmlDocument.parse(xml);
    final cells = <int, Map<int, String>>{};
    final bold = <int>{};
    final numeric = <int>{};
    var maxRow = -1, maxCol = -1;

    var nextRow = 0;
    for (final row in _all(doc, 'row')) {
      final r = (int.tryParse(_attr(row, 'r') ?? '') ?? (nextRow + 1)) - 1;
      nextRow = r + 1;
      var nextCol = 0;
      for (final c in _children(row, 'c')) {
        final pos = _ref(_attr(c, 'r') ?? '');
        final col = pos?.$2 ?? nextCol;
        nextCol = col + 1;
        final style = int.tryParse(_attr(c, 's') ?? '') ?? 0;
        final v = _child(c, 'v')?.innerText;
        String? text;
        var isNumber = false;
        switch (_attr(c, 't')) {
          case 's':
            final i = int.tryParse(v ?? '');
            text = i != null && i < shared.length ? shared[i] : null;
          case 'inlineStr':
            final inline = _child(c, 'is');
            text = inline == null ? null : _all(inline, 't').map((t) => t.innerText).join();
          case 'str' || 'e':
            text = v;
          case 'b':
            text = v == null ? null : (v == '1' ? 'TRUE' : 'FALSE');
          case 'd':
            final d = v == null ? null : DateTime.tryParse(v);
            text = d == null ? v : formatDate(d, 'dd/mm/yyyy${d.hour + d.minute + d.second > 0 ? ' hh:mm' : ''}');
          default:
            final n = double.tryParse(v ?? '');
            if (n != null) {
              text = formatNumber(n, styles.formatOf(style), date1904: date1904);
              isNumber = true;
            } else {
              text = v;
            }
        }
        if (text == null || text.isEmpty) continue;
        (cells[r] ??= {})[col] = text;
        final k = SheetData.key(r, col);
        if (isNumber) numeric.add(k);
        if (styles.isBold(style)) bold.add(k);
        maxRow = math.max(maxRow, r);
        maxCol = math.max(maxCol, col);
      }
    }

    final widths = <int, double>{};
    for (final col in _all(doc, 'col')) {
      final min = int.tryParse(_attr(col, 'min') ?? '') ?? 0;
      final max = int.tryParse(_attr(col, 'max') ?? '') ?? 0;
      final w = double.tryParse(_attr(col, 'width') ?? '');
      final hidden = ['1', 'true'].contains(_attr(col, 'hidden'));
      if (w == null || min < 1) continue;
      for (var i = min; i <= math.min(max, 2000); i++) {
        widths[i - 1] = hidden ? 0 : w;
      }
    }

    final merges = <SheetMerge>[];
    for (final m in _all(doc, 'mergeCell')) {
      final parts = (_attr(m, 'ref') ?? '').split(':');
      if (parts.length != 2) continue;
      final a = _ref(parts[0]), b = _ref(parts[1]);
      if (a == null || b == null) continue;
      final r0 = math.min(a.$1, b.$1), c0 = math.min(a.$2, b.$2);
      final rs = (a.$1 - b.$1).abs() + 1, cs = (a.$2 - b.$2).abs() + 1;
      if (rs * cs <= 1) continue;
      merges.add(SheetMerge(r0, c0, rs, cs));
      maxRow = math.max(maxRow, r0 + rs - 1);
      maxCol = math.max(maxCol, c0 + cs - 1);
    }

    return SheetData(
      name: name,
      cells: cells,
      rowCount: maxRow + 1,
      colCount: maxCol + 1,
      colWidths: widths,
      merges: merges,
      bold: bold,
      numeric: numeric,
    );
  }
}

/// Number formats and bold fonts from styles.xml (indexed by the cell's "s").
class _Styles {
  _Styles(this._xfFormat, this._xfBold, this._formats);
  final List<int> _xfFormat;
  final List<bool> _xfBold;
  final Map<int, String> _formats;

  static _Styles parse(String? xml) {
    if (xml == null) return _Styles(const [], const [], const {});
    final doc = XmlDocument.parse(xml);
    final formats = <int, String>{};
    for (final f in _all(doc, 'numFmt')) {
      final id = int.tryParse(_attr(f, 'numFmtId') ?? '');
      if (id != null) formats[id] = _attr(f, 'formatCode') ?? 'General';
    }
    final fontBold = <bool>[];
    final fonts = _all(doc, 'fonts').firstOrNull;
    if (fonts != null) {
      for (final font in _children(fonts, 'font')) {
        final b = _child(font, 'b');
        fontBold.add(b != null && !['0', 'false'].contains(_attr(b, 'val')));
      }
    }
    final xfFormat = <int>[];
    final xfBold = <bool>[];
    final cellXfs = _all(doc, 'cellXfs').firstOrNull;
    if (cellXfs != null) {
      for (final xf in _children(cellXfs, 'xf')) {
        xfFormat.add(int.tryParse(_attr(xf, 'numFmtId') ?? '') ?? 0);
        final font = int.tryParse(_attr(xf, 'fontId') ?? '') ?? 0;
        xfBold.add(font < fontBold.length && fontBold[font]);
      }
    }
    return _Styles(xfFormat, xfBold, formats);
  }

  String formatOf(int style) {
    final id = style < _xfFormat.length ? _xfFormat[style] : 0;
    return _formats[id] ?? _builtinFormats[id] ?? ((id >= 27 && id <= 36) || (id >= 50 && id <= 58) ? 'yyyy-mm-dd' : 'General');
  }

  bool isBold(int style) => style < _xfBold.length && _xfBold[style];
}

/// Excel's built-in number formats (14 is the phone's short date; dd/mm/yyyy here).
const _builtinFormats = <int, String>{
  0: 'General', 1: '0', 2: '0.00', 3: '#,##0', 4: '#,##0.00', 9: '0%', 10: '0.00%', 11: '0.00E+00',
  12: 'General', 13: 'General', 14: 'dd/mm/yyyy', 15: 'd-mmm-yy', 16: 'd-mmm', 17: 'mmm-yy',
  18: 'h:mm AM/PM', 19: 'h:mm:ss AM/PM', 20: 'h:mm', 21: 'h:mm:ss', 22: 'dd/mm/yyyy h:mm',
  37: '#,##0', 38: '#,##0', 39: '#,##0.00', 40: '#,##0.00', 45: 'mm:ss', 46: '[h]:mm:ss',
  47: 'mm:ss', 48: '0.0E+0', 49: '@',
};

// ---- Number formatting ------------------------------------------------------------------

/// Shows [v] the way Excel would with [format] (common formats; colours ignored).
String formatNumber(double v, String format, {bool date1904 = false}) {
  if (format == 'General' || format == '@' || format.isEmpty) return _general(v);
  // Positive;negative;zero;text sections: use the first, add "-" for negatives.
  final section = format.split(';').first;
  final shown = _literalFormat(section); // with literal text kept (₹, "kg")
  final codes = _codesOnly(section); // only the format codes
  if (codes.isEmpty) return shown.trim().isEmpty ? _general(v) : shown;

  if (_isDateFormat(codes)) {
    final base = date1904 ? DateTime.utc(1904, 1, 1) : DateTime.utc(1899, 12, 30);
    final d = base.add(Duration(milliseconds: (v * 86400000).round()));
    return formatDate(d, shown);
  }

  final placeholders = RegExp(r'[0#?.,%]|E[+-]', caseSensitive: false);
  final first = shown.indexOf(placeholders);
  final last = shown.lastIndexOf(placeholders);
  final prefix = first < 0 ? '' : shown.substring(0, first);
  final suffix = last < 0 ? '' : shown.substring(last + 1).replaceAll('%', '');

  final dot = codes.indexOf('.');
  final decimals = dot < 0 ? 0 : RegExp(r'^[0#?]*').stringMatch(codes.substring(dot + 1))!.length;
  var n = v;
  String body;
  if (codes.contains(RegExp('E[+-]', caseSensitive: false))) {
    body = v.toStringAsExponential(decimals).toUpperCase().replaceFirstMapped(
        RegExp(r'E([+-])(\d)$'), (m) => 'E${m[1]}0${m[2]}');
  } else {
    if (codes.contains('%')) n *= 100;
    // Trailing commas after the digits divide by 1000 ("#,##0," = thousands).
    final scale = RegExp(r'[0#?](,+)(?![0#?])').firstMatch(codes)?.group(1)?.length ?? 0;
    for (var i = 0; i < scale; i++) {
      n /= 1000;
    }
    final grouping = RegExp(r'[0#?],[0#?]').hasMatch(codes);
    final indian = codes.contains('##,##,');
    body = _fixed(n, decimals, grouping, indian);
    if (codes.contains('%')) body = '$body%';
  }
  return '$prefix$body$suffix'.trim();
}

String _general(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  final abs = v.abs();
  if (abs != 0 && (abs < 1e-9 || abs >= 1e15)) return v.toStringAsExponential(5).toUpperCase();
  var s = v.toStringAsPrecision(10); // Excel "General" shows about 10 significant digits
  if (s.contains('e')) return v.toString();
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return s;
}

String _fixed(double v, int decimals, bool grouping, bool indian) {
  var s = v.abs().toStringAsFixed(decimals);
  if (grouping) {
    final parts = s.split('.');
    var whole = parts[0];
    if (indian && whole.length > 3) {
      // 12,34,567 (lakh / crore)
      final last3 = whole.substring(whole.length - 3);
      var rest = whole.substring(0, whole.length - 3);
      final groups = <String>[];
      while (rest.length > 2) {
        groups.insert(0, rest.substring(rest.length - 2));
        rest = rest.substring(0, rest.length - 2);
      }
      if (rest.isNotEmpty) groups.insert(0, rest);
      whole = '${groups.join(',')},$last3';
    } else {
      whole = whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    }
    s = parts.length > 1 ? '$whole.${parts[1]}' : whole;
  }
  final isZero = RegExp(r'^[0.,]*$').hasMatch(s);
  return v < 0 && !isZero ? '-$s' : s;
}

/// Format with literal text resolved: "text" → text, \x → x, [$₹-4009] → ₹,
/// [h] kept (elapsed time), other [..] (colours, conditions) removed, _x → space, *x removed.
String _literalFormat(String f) {
  final b = StringBuffer();
  var i = 0;
  while (i < f.length) {
    final ch = f[i];
    if (ch == '"') {
      final end = f.indexOf('"', i + 1);
      b.write(end < 0 ? f.substring(i + 1) : f.substring(i + 1, end));
      i = end < 0 ? f.length : end + 1;
    } else if (ch == '\\' && i + 1 < f.length) {
      b.write(f[i + 1]);
      i += 2;
    } else if (ch == '[') {
      final end = f.indexOf(']', i);
      final inner = end < 0 ? '' : f.substring(i + 1, end);
      if (inner.startsWith(r'$')) {
        b.write(inner.substring(1).split('-').first);
      } else if (RegExp(r'^[hms]+$', caseSensitive: false).hasMatch(inner)) {
        b.write(inner);
      }
      i = end < 0 ? f.length : end + 1;
    } else if (ch == '_' && i + 1 < f.length) {
      b.write(' ');
      i += 2;
    } else if (ch == '*' && i + 1 < f.length) {
      i += 2;
    } else {
      b.write(ch);
      i++;
    }
  }
  return b.toString();
}

/// Only the format codes (literal text removed), to decide date / percent / decimals.
String _codesOnly(String f) => _literalFormat(f
        .replaceAll(RegExp(r'"[^"]*"'), '')
        .replaceAll(RegExp(r'\\.'), '')
        .replaceAll(RegExp(r'\[\$[^\]]*\]'), ''))
    .replaceAll(RegExp(r'[^0#?.,%Eeymdhs/:+\-APap ]'), '');

bool _isDateFormat(String codes) => RegExp('[ymdhs]', caseSensitive: false).hasMatch(codes.replaceAll(RegExp('E[+-]'), ''));

/// Formats [d] with an Excel date/time pattern (yyyy, mmm, dd, hh, mm, ss, AM/PM…).
String formatDate(DateTime d, String pattern) {
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
    'October', 'November', 'December'];
  const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  String two(int n) => n.toString().padLeft(2, '0');
  final lower = pattern.toLowerCase();
  final ampm = lower.contains('am/pm') || lower.contains('a/p');
  final out = StringBuffer();
  var afterHour = false;
  var i = 0;
  int run(String c) {
    var j = i;
    while (j < lower.length && lower[j] == c) {
      j++;
    }
    return j - i;
  }

  /// "m" is minutes right after an hour or right before seconds.
  bool minutesAhead() {
    var j = i;
    while (j < lower.length && lower[j] == 'm') {
      j++;
    }
    while (j < lower.length && !'ymdhs'.contains(lower[j])) {
      j++;
    }
    return j < lower.length && lower[j] == 's';
  }

  while (i < pattern.length) {
    if (lower.startsWith('am/pm', i)) {
      out.write(d.hour < 12 ? 'AM' : 'PM');
      i += 5;
      continue;
    }
    if (lower.startsWith('a/p', i)) {
      out.write(d.hour < 12 ? 'A' : 'P');
      i += 3;
      continue;
    }
    final ch = lower[i];
    final n = 'ymdhs'.contains(ch) ? run(ch) : 1;
    switch (ch) {
      case 'y':
        out.write(n <= 2 ? two(d.year % 100) : '${d.year}');
        afterHour = false;
      case 'd':
        out.write(switch (n) {
          1 => '${d.day}',
          2 => two(d.day),
          3 => days[d.weekday - 1].substring(0, 3),
          _ => days[d.weekday - 1],
        });
        afterHour = false;
      case 'h':
        final h = ampm ? (d.hour % 12 == 0 ? 12 : d.hour % 12) : d.hour;
        out.write(n >= 2 ? two(h) : '$h');
        afterHour = true;
      case 'm':
        if (afterHour || minutesAhead()) {
          out.write(n >= 2 ? two(d.minute) : '${d.minute}');
        } else {
          out.write(switch (n) {
            1 => '${d.month}',
            2 => two(d.month),
            3 => months[d.month - 1].substring(0, 3),
            4 => months[d.month - 1],
            _ => months[d.month - 1][0],
          });
        }
        afterHour = false;
      case 's':
        out.write(n >= 2 ? two(d.second) : '${d.second}');
        afterHour = false;
      default:
        out.write(pattern[i]);
    }
    i += n;
  }
  return out.toString();
}

// ---- CSV ----------------------------------------------------------------------------------

SheetData _parseCsv(Uint8List bytes, String fileName) {
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.startsWith('﻿')) text = text.substring(1);
  if (text.contains('\u0000')) throw const SheetFormatException('This file is not a spreadsheet.');

  // Separator: whichever of , ; tab appears most in the first line.
  final firstLine = text.split('\n').first;
  final sep = [',', ';', '\t'].reduce((a, b) => b.allMatches(firstLine).length > a.allMatches(firstLine).length ? b : a);

  final cells = <int, Map<int, String>>{};
  final numeric = <int>{};
  var row = 0, col = 0, maxCol = -1, maxRow = -1;
  final field = StringBuffer();
  var quoted = false;

  void endField() {
    final value = field.toString();
    field.clear();
    if (value.isNotEmpty) {
      (cells[row] ??= {})[col] = value;
      if (double.tryParse(value.replaceAll(',', '')) != null) numeric.add(SheetData.key(row, col));
      maxCol = math.max(maxCol, col);
      maxRow = math.max(maxRow, row);
    }
    col++;
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(ch);
      }
    } else if (ch == '"' && field.isEmpty) {
      quoted = true;
    } else if (ch == sep) {
      endField();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      endField();
      row++;
      col = 0;
    } else {
      field.write(ch);
    }
  }
  if (field.isNotEmpty || col > 0) endField();

  final name = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
  return SheetData(
      name: name.isEmpty ? 'Sheet 1' : name, cells: cells, rowCount: maxRow + 1, colCount: maxCol + 1, numeric: numeric);
}
