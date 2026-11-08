import 'dart:convert';
import 'dart:typed_data';

import 'package:abhi_utility/excel/sheet_reader.dart';
import 'package:abhi_utility/excel/sheet_writer.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// A small but real .xlsx: shared strings, a formula with its cached result,
/// styles (date, percent, rupees, bold), column widths, a merged title and a hidden sheet.
Uint8List _xlsx() {
  final files = <String, String>{
    'xl/workbook.xml': '''<?xml version="1.0"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
    <sheet name="Budget" sheetId="1" r:id="rId1"/>
    <sheet name="Secret" sheetId="2" state="hidden" r:id="rId2"/>
  </sheets>
</workbook>''',
    'xl/_rels/workbook.xml.rels': '''<?xml version="1.0"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2" Type="worksheet" Target="/xl/worksheets/sheet2.xml"/>
</Relationships>''',
    'xl/sharedStrings.xml': '''<?xml version="1.0"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <si><t>Monthly budget</t></si>
  <si><t>Item</t></si>
  <si><r><t>Ren</t></r><r><t>t</t></r></si>
</sst>''',
    'xl/styles.xml': '''<?xml version="1.0"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <numFmts><numFmt numFmtId="164" formatCode="[\$₹-4009]\\ #,##0.00"/></numFmts>
  <fonts><font/><font><b/></font></fonts>
  <cellXfs>
    <xf numFmtId="0" fontId="0"/>
    <xf numFmtId="0" fontId="1"/>
    <xf numFmtId="14" fontId="0"/>
    <xf numFmtId="10" fontId="0"/>
    <xf numFmtId="164" fontId="0"/>
  </cellXfs>
</styleSheet>''',
    'xl/worksheets/sheet1.xml': '''<?xml version="1.0"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <cols><col min="1" max="1" width="20" customWidth="1"/></cols>
  <sheetData>
    <row r="1"><c r="A1" t="s" s="1"><v>0</v></c></row>
    <row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2"><v>45658</v></c></row>
    <row r="3"><c r="A3" t="s"><v>2</v></c><c r="B3" s="4"><v>1234567.5</v></c><c r="C3" s="3"><v>0.125</v></c></row>
    <row r="4"><c r="B4" s="4"><f>SUM(B3:B3)</f><v>1234567.5</v></c><c r="C4" s="2"><v>45658</v></c></row>
    <row r="5"><c r="A5" t="inlineStr"><is><t>Done?</t></is></c><c r="B5" t="b"><v>1</v></c><c r="C5"><v>0.1</v></c></row>
  </sheetData>
  <mergeCells count="1"><mergeCell ref="A1:C1"/></mergeCells>
</worksheet>''',
    'xl/worksheets/sheet2.xml': '<worksheet><sheetData/></worksheet>',
  };
  final archive = Archive();
  files.forEach((name, text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  test('reads an xlsx workbook', () {
    final wb = parseWorkbook(_xlsx(), 'budget.xlsx');
    expect(wb.sheets.map((s) => s.name), ['Budget']); // hidden sheet skipped
    final s = wb.sheets.first;
    expect(s.rowCount, 5);
    expect(s.colCount, 3);
    expect(s.cell(0, 0), 'Monthly budget');
    expect(s.bold.contains(SheetData.key(0, 0)), isTrue);
    expect(s.cell(2, 0), 'Rent'); // rich text runs joined
    expect(s.cell(1, 1), '45658'); // general number
    expect(s.cell(2, 1), '₹ 1,234,567.50'); // currency symbol from [$₹-4009], grouping
    expect(s.cell(3, 1), '₹ 1,234,567.50'); // formula: cached result, not "SUM(...)"
    expect(s.cell(2, 2), '12.50%');
    expect(s.cell(3, 2), '01/01/2025'); // built-in date format 14
    expect(s.cell(4, 0), 'Done?');
    expect(s.cell(4, 1), 'TRUE');
    expect(s.cell(4, 2), '0.1');
    expect(s.numeric.contains(SheetData.key(2, 1)), isTrue);
    expect(s.colWidths[0], 20);
    expect(s.merges.single.colSpan, 3);
  });

  test('number formats', () {
    expect(formatNumber(1234567.891, '#,##0.00'), '1,234,567.89');
    expect(formatNumber(1234567, '##,##,##0'), '12,34,567');
    expect(formatNumber(-42.5, '0.0'), '-42.5');
    expect(formatNumber(-0.001, '0.00'), '0.00');
    expect(formatNumber(0.5, '0%'), '50%');
    expect(formatNumber(12345, '0.00E+00'), '1.23E+04');
    expect(formatNumber(1500000, '#,##0,"K"'), '1,500K');
    expect(formatNumber(45658.75, 'dd-mmm-yyyy h:mm AM/PM'), '01-Jan-2025 6:00 PM');
    expect(formatNumber(0.5, 'hh:mm:ss'), '12:00:00');
    expect(formatNumber(45658, 'mmmm d, yyyy'), 'January 1, 2025');
    expect(formatNumber(1 / 3, 'General'), '0.3333333333');
    expect(formatNumber(0.1 + 0.2, 'General'), '0.3');
  });

  test('reads csv with quotes and semicolons', () {
    final csv = utf8.encode('﻿Name;Note;Amount\r\nAsha;"says ""hi""; ok";1200\nRavi;"two\nlines";99.5\n');
    final s = parseWorkbook(Uint8List.fromList(csv), 'list.csv').sheets.single;
    expect(s.name, 'list');
    expect(s.rowCount, 3);
    expect(s.cell(0, 0), 'Name');
    expect(s.cell(1, 1), 'says "hi"; ok');
    expect(s.cell(2, 1), 'two\nlines');
    expect(s.numeric.contains(SheetData.key(1, 2)), isTrue);
  });

  test('old .xls gives a clear message', () {
    final xls = Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0, 0, 0, 0]);
    expect(() => parseWorkbook(xls, 'old.xls'), throwsA(isA<SheetFormatException>()));
  });

  test('column names', () {
    expect([0, 25, 26, 701, 702].map(columnName), ['A', 'Z', 'AA', 'ZZ', 'AAA']);
  });

  test('typed input becomes number / formula / text', () {
    expect(parseInput('1,234.5').kind, CellKind.number);
    expect(parseInput('1,234.5').value, '1234.5');
    expect(parseInput('12.5%').value, '0.125');
    expect(parseInput('=SUM(A1:A3)').value, 'SUM(A1:A3)');
    expect(parseInput('09876543210').kind, CellKind.text); // phone number keeps its 0
    expect(parseInput('+91 98765').kind, CellKind.text);
    expect(parseInput('hello').kind, CellKind.text);
    expect(parseInput('  ').kind, CellKind.empty);
    expect(parseInput('05/01/2025', format: 'dd/mm/yyyy').value, '45662');
    expect(parseInput('05/01/2025').kind, CellKind.text); // not a date cell
  });

  test('edits are saved into the xlsx and read back', () {
    final original = _xlsx();
    final book = parseWorkbook(original, 'budget.xlsx');
    final s = book.sheets.first;
    expect(s.formulas[SheetData.key(3, 1)], 'SUM(B3:B3)');
    expect(editText(s, 3, 1), '=SUM(B3:B3)');
    expect(editText(s, 2, 1), '1234567.5'); // the number, not "₹ 1,234,567.50"
    final edits = <int, String>{
      SheetData.key(2, 1): '2000', // keeps its ₹ format
      SheetData.key(2, 0): 'House rent', // replaces a shared string
      SheetData.key(4, 1): '', // cleared
      SheetData.key(9, 4): 'new far cell', // E10: new row and column
      SheetData.key(3, 2): '=B3*2',
    };
    edits.forEach((k, v) => setCell(s, k ~/ 16384, k % 16384, v, csv: false));
    expect(s.cell(2, 1), '₹ 2,000.00');
    expect(s.rowCount, 10);

    // A new sheet too.
    final extra = SheetData(name: 'Notes', cells: {}, rowCount: 0, colCount: 0);
    setCell(extra, 0, 0, 'hello', csv: false);
    book.sheets.add(extra);

    final saved = saveXlsx(original, book, {s: edits, extra: {SheetData.key(0, 0): 'hello'}});
    final again = parseWorkbook(saved, 'budget.xlsx');
    expect(again.sheets.map((x) => x.name), ['Budget', 'Notes']);
    final s2 = again.sheets.first;
    expect(s2.cell(2, 1), '₹ 2,000.00');
    expect(s2.cell(2, 0), 'House rent');
    expect(s2.cell(4, 1), null);
    expect(s2.cell(9, 4), 'new far cell');
    expect(s2.formulas[SheetData.key(3, 2)], 'B3*2');
    expect(s2.cell(0, 0), 'Monthly budget'); // untouched cells stay
    expect(s2.merges.length, 1);
    expect(again.sheets[1].cell(0, 0), 'hello');

    final zip = ZipDecoder().decodeBytes(saved);
    final wb = utf8.decode(zip.findFile('xl/workbook.xml')!.content);
    expect(wb.contains('fullCalcOnLoad="1"'), isTrue);
    final sheet = utf8.decode(zip.findFile('xl/worksheets/sheet1.xml')!.content);
    expect(sheet.indexOf('r="E10"') > sheet.indexOf('r="C4"'), isTrue); // rows stay in order
  });

  test('new workbook', () {
    final book = parseWorkbook(newWorkbook(), 'new.xlsx');
    final s = book.sheets.single;
    expect(s.name, 'Sheet1');
    expect(s.isEmpty, isTrue);
    setCell(s, 0, 0, 'Name', csv: false);
    setCell(s, 1, 0, '42', csv: false);
    final again = parseWorkbook(saveXlsx(newWorkbook(), book, {s: {0: 'Name', 16384: '42'}}), 'new.xlsx');
    expect(again.sheets.single.cell(0, 0), 'Name');
    expect(again.sheets.single.cell(1, 0), '42');
  });

  test('csv save', () {
    final book = parseWorkbook(Uint8List.fromList(utf8.encode('a;b\n1;2\n')), 'x.csv');
    expect(book.csvSeparator, ';');
    final s = book.sheets.single;
    setCell(s, 1, 1, 'x;y "z"', csv: true);
    setCell(s, 2, 0, 'new', csv: true);
    final again = parseWorkbook(saveCsv(s, book.csvSeparator!), 'x.csv').sheets.single;
    expect(again.cell(1, 1), 'x;y "z"');
    expect(again.cell(2, 0), 'new');
    expect(again.cell(0, 1), 'b');
  });
}
