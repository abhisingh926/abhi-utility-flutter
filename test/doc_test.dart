import 'dart:convert';
import 'dart:typed_data';

import 'package:abhi_utility/docs/doc_reader.dart';
import 'package:abhi_utility/docs/doc_writer.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

const _w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

/// A small real .docx: a heading, mixed bold/plain text, a numbered list, a link, a table.
Uint8List _docx() {
  final files = {
    'word/document.xml': '''<?xml version="1.0"?>
<w:document xmlns:w="$_w" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
  <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Report</w:t></w:r></w:p>
  <w:p><w:r><w:t xml:space="preserve">Hello </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>bold</w:t></w:r><w:r><w:t xml:space="preserve"> world</w:t></w:r></w:p>
  <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>First</w:t></w:r></w:p>
  <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Second</w:t></w:r></w:p>
  <w:p><w:hyperlink r:id="rId9"><w:r><w:t>a link</w:t></w:r></w:hyperlink><w:r><w:tab/><w:t>tabbed</w:t></w:r></w:p>
  <w:tbl><w:tr><w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B1</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
  <w:p><w:pPr><w:sectPr/></w:pPr><w:r><w:t>Last</w:t></w:r></w:p>
  <w:sectPr/>
</w:body></w:document>''',
    'word/styles.xml': '''<?xml version="1.0"?>
<w:styles xmlns:w="$_w">
  <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="24"/></w:rPr></w:rPrDefault></w:docDefaults>
  <w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
</w:styles>''',
    'word/numbering.xml': '''<?xml version="1.0"?>
<w:numbering xmlns:w="$_w">
  <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl></w:abstractNum>
  <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
</w:numbering>''',
  };
  final archive = Archive();
  files.forEach((name, text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

List<DocParagraph> _paras(DocDocument d) {
  final out = <DocParagraph>[];
  void walk(List<DocBlock> blocks) {
    for (final b in blocks) {
      switch (b) {
        case DocParagraph():
          out.add(b);
        case DocTable():
          for (final row in b.rows) {
            for (final cell in row) {
              walk(cell);
            }
          }
      }
    }
  }

  walk(d.blocks);
  return out;
}

void main() {
  test('reads a docx', () {
    final d = parseDocument(_docx(), 'r.docx');
    final ps = _paras(d);
    expect(ps.map((p) => p.text), ['Report', 'Hello bold world', 'First', 'Second', 'a link\ttabbed', 'A1', 'B1', 'Last']);
    expect(ps.map((p) => p.pid), [0, 1, 2, 3, 4, 5, 6, 7]);
    expect(ps[0].style, 'h1');
    expect(ps[0].baseSize, 16);
    expect(ps[1].baseSize, 12);
    expect(ps[1].runs[1].bold, isTrue);
    expect(ps[1].runs[0].bold, false);
    expect(ps[2].listLabel, '1.');
    expect(ps[3].listLabel, '2.');
    expect(ps[4].runs.first.link, isTrue);
    expect(d.blocks.whereType<DocTable>().length, 1);
  });

  test('editing keeps the formatting of untouched words', () {
    final edits = DocEdits();
    edits.of(1).text = 'Hello very bold world!'; // typed inside the bold run and at the end
    edits.of(0).style = 'h2'; // style not in the file yet: gets added
    edits.of(3).delete = true;
    edits.of(5).text = 'A1 changed'; // table cell
    edits.of(7).delete = true; // carries section settings: emptied, not removed
    edits.inserted.add(NewParagraph(anchorPid: 2, text: 'One and a half'));
    edits.inserted.add(NewParagraph(anchorPid: 0, text: 'Intro', before: true, style: 'title', align: 'center'));
    edits.of(4).bold = true;
    final saved = saveDocx(_docx(), edits);

    final ps = _paras(parseDocument(saved, 'r.docx'));
    expect(ps.map((p) => p.text),
        ['Intro', 'Report', 'Hello very bold world!', 'First', 'One and a half', 'a link\ttabbed', 'A1 changed', 'B1', '']);
    final hello = ps[2];
    // Typed text takes the formatting of the character before it (as in Word); "bold" stays bold.
    expect(hello.runs.map((r) => r.text), ['Hello very ', 'bold', ' world!']);
    expect(hello.runs[1].bold, isTrue);
    expect(hello.runs[0].bold, false);
    expect(hello.runs[2].bold, false);
    expect(ps[0].style, 'title');
    expect(ps[0].align, 'center');
    expect(ps[1].style, 'h2');
    expect(ps[4].listLabel, '2.'); // new paragraph continues the list
    expect(ps[5].runs.every((r) => r.bold), isTrue);

    final zip = ZipDecoder().decodeBytes(saved);
    final styles = utf8.decode(zip.findFile('word/styles.xml')!.content);
    expect(styles.contains('w:styleId="Heading2"'), isTrue);
    expect(styles.contains('w:styleId="Title"'), isTrue);
    final xml = utf8.decode(zip.findFile('word/document.xml')!.content);
    // rPr children in schema order: b before i, rPr first in the run.
    expect(RegExp(r'<w:r><w:rPr>').hasMatch(xml), isTrue);
  });

  test('new document', () {
    final d = parseDocument(newDocument(), 'n.docx');
    expect(_paras(d).single.text, '');
    final edits = DocEdits()..of(0).text = 'Hello';
    edits.inserted.add(NewParagraph(anchorPid: 0, text: 'Big title', before: true, style: 'h1'));
    final again = _paras(parseDocument(saveDocx(newDocument(), edits), 'n.docx'));
    expect(again.map((p) => p.text), ['Big title', 'Hello']);
    expect(again.first.style, 'h1');
  });

  test('plain text', () {
    final d = parseDocument(Uint8List.fromList(utf8.encode('line 1\r\nline 2\n')), 'a.txt');
    expect(d.plainText, isTrue);
    expect(_paras(d).map((p) => p.text), ['line 1', 'line 2']);
    expect(utf8.decode(saveText(['a', 'b'])), 'a\nb\n');
  });

  test('old .doc gives a clear message', () {
    expect(() => parseDocument(Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0, 0]), 'x.doc'),
        throwsA(isA<DocFormatException>()));
  });
}
