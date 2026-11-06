import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// One page of the PDF: an image file and how many quarter turns to rotate it.
typedef PageSpec = ({String path, int quarterTurns});

/// Builds an A4 PDF with one image per page (in a background isolate).
///
/// Each image is fitted inside the page; wide images get a landscape page.
/// With [pageNumbers], "Page X of N" is printed at the bottom.
Future<Uint8List> buildPdf(List<PageSpec> pages, {required bool pageNumbers, String? title}) {
  return Isolate.run(() async {
    final doc = pw.Document(title: title, creator: 'Abhi Utility');
    final total = pages.length;

    for (var i = 0; i < total; i++) {
      final spec = pages[i];
      final image = pw.MemoryImage(File(spec.path).readAsBytesSync());
      final turns = spec.quarterTurns % 4;
      final w = (turns.isOdd ? image.height : image.width) ?? 1;
      final h = (turns.isOdd ? image.width : image.height) ?? 1;
      final format = w > h ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;

      doc.addPage(pw.Page(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(18),
        build: (context) => pw.Column(
          children: [
            pw.Expanded(
              child: pw.Center(
                child: pw.Transform.rotateBox(
                  angle: -turns * math.pi / 2,
                  child: pw.Image(image, fit: pw.BoxFit.contain),
                ),
              ),
            ),
            if (pageNumbers)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 8),
                child: pw.Text(
                  'Page ${i + 1} of $total',
                  style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
                ),
              ),
          ],
        ),
      ));
    }
    return doc.save();
  });
}
