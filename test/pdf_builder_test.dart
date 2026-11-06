import 'dart:convert';
import 'dart:io';

import 'package:abhi_utility/pdf/pdf_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds a multi-page PDF from images', () async {
    // 4x2 red PNG.
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAIAAADwyuo0AAAAEElEQVR4nGP8z4AATEhsBgAZNQEDGy9LEgAAAABJRU5ErkJggg==';
    final dir = await Directory.systemTemp.createTemp('pdf_test');
    final file = File('${dir.path}/img.png')..writeAsBytesSync(base64Decode(png));

    final bytes = await buildPdf(
      [(path: file.path, quarterTurns: 0), (path: file.path, quarterTurns: 1)],
      pageNumbers: true,
      title: 'Test',
    );

    expect(utf8.decode(bytes.sublist(0, 5)), '%PDF-');
    // Two pages in the document.
    expect(RegExp(r'/Type\s*/Page[^s]').allMatches(latin1.decode(bytes)).length, 2);
    await dir.delete(recursive: true);
  });
}
