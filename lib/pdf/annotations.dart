import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

/// Marks drawn on one page. All positions are fractions (0..1) of the page
/// width/height and sizes are fractions of the page width, so they can be drawn
/// at any resolution (screen preview or the saved PDF).
class PageAnnotations {
  final List<Stroke> strokes = [];
  final List<TextNote> texts = [];
  final List<SignatureMark> signatures = [];

  /// Undo order: last added mark first.
  final List<Object> _history = [];

  bool get isEmpty => strokes.isEmpty && texts.isEmpty && signatures.isEmpty;

  void add(Object mark) {
    switch (mark) {
      case Stroke s:
        strokes.add(s);
      case TextNote t:
        texts.add(t);
      case SignatureMark m:
        signatures.add(m);
    }
    _history.add(mark);
  }

  void undo() {
    if (_history.isEmpty) return;
    final last = _history.removeLast();
    strokes.remove(last);
    texts.remove(last);
    signatures.remove(last);
  }

  PageAnnotations copy() {
    final c = PageAnnotations();
    for (final m in _history) {
      c.add(m);
    }
    return c;
  }
}

class Stroke {
  Stroke({required this.color, required this.width, this.highlighter = false});
  final List<Offset> points = [];
  final Color color;

  /// Line width as a fraction of the page width.
  final double width;
  final bool highlighter;
}

class TextNote {
  TextNote({required this.position, required this.text, required this.color, this.size = 0.035});

  /// Top-left of the text.
  final Offset position;
  final String text;
  final Color color;

  /// Font size as a fraction of the page width.
  final double size;
}

/// A hand-drawn signature: strokes in its own box (0..1 x 0..1/aspect).
class Signature {
  Signature(this.strokes, this.aspect);
  final List<List<Offset>> strokes;

  /// width / height of the signature box.
  final double aspect;
}

class SignatureMark {
  SignatureMark({required this.signature, required this.position, this.width = 0.35});
  final Signature signature;

  /// Top-left of the signature.
  final Offset position;

  /// Width as a fraction of the page width.
  final double width;
}

/// Draws [a] onto a page area of [size] pixels.
void paintAnnotations(Canvas canvas, Size size, PageAnnotations a) {
  Offset p(Offset f) => Offset(f.dx * size.width, f.dy * size.height);

  for (final s in a.strokes) {
    if (s.points.isEmpty) continue;
    final paint = Paint()
      ..color = s.color
      ..strokeWidth = s.width * size.width
      ..style = PaintingStyle.stroke
      ..strokeCap = s.highlighter ? StrokeCap.square : StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..blendMode = s.highlighter ? BlendMode.multiply : BlendMode.srcOver;
    final path = Path()..moveTo(p(s.points.first).dx, p(s.points.first).dy);
    for (final pt in s.points.skip(1)) {
      path.lineTo(p(pt).dx, p(pt).dy);
    }
    if (s.points.length == 1) path.lineTo(p(s.points.first).dx + 0.1, p(s.points.first).dy);
    canvas.drawPath(path, paint);
  }

  for (final t in a.texts) {
    final tp = TextPainter(
      text: TextSpan(
        text: t.text,
        style: TextStyle(color: t.color, fontSize: t.size * size.width, fontWeight: FontWeight.w500),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(1, size.width - p(t.position).dx));
    tp.paint(canvas, p(t.position));
  }

  for (final m in a.signatures) {
    final w = m.width * size.width;
    final h = w / m.signature.aspect;
    final origin = p(m.position);
    final paint = Paint()
      ..color = const Color(0xFF0D1B6E)
      ..strokeWidth = math.max(1.5, w * 0.012)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final stroke in m.signature.strokes) {
      if (stroke.isEmpty) continue;
      final path = Path()..moveTo(origin.dx + stroke.first.dx * w, origin.dy + stroke.first.dy * h);
      for (final pt in stroke.skip(1)) {
        path.lineTo(origin.dx + pt.dx * w, origin.dy + pt.dy * h);
      }
      canvas.drawPath(path, paint);
    }
  }
}

/// Renders [page] at [pixelWidth] wide as a Flutter image (caller disposes it).
Future<ui.Image> renderPage(PdfPage page, double pixelWidth) async {
  final h = pixelWidth * page.height / page.width;
  final rendered = await page.render(
    fullWidth: pixelWidth,
    fullHeight: h,
    backgroundColor: 0xFFFFFFFF,
  );
  if (rendered == null) throw Exception('Could not render page');
  try {
    return await rendered.createImage();
  } finally {
    rendered.dispose();
  }
}

/// Burns [a] into [page]: renders the page (≈180 dpi), draws the marks, and
/// returns a one-page document holding the result as an image page.
/// The caller must keep the returned document alive until the PDF is saved.
Future<PdfDocument> flattenPage(PdfPage page, PageAnnotations a, String id) async {
  const scale = 2.5; // 72 dpi * 2.5 = 180 dpi
  final w = (page.width * scale).round();
  final h = (page.height * scale).round();

  final background = await renderPage(page, w.toDouble());
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImageRect(
    background,
    Rect.fromLTWH(0, 0, background.width.toDouble(), background.height.toDouble()),
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..filterQuality = FilterQuality.high,
  );
  background.dispose();
  paintAnnotations(canvas, Size(w.toDouble(), h.toDouble()), a);
  final composed = await recorder.endRecording().toImage(w, h);
  final bytes = await composed.toByteData(format: ui.ImageByteFormat.rawRgba);
  composed.dispose();

  // Encoding a ~1500×2100 page in Dart takes up to a second: do it off the UI thread.
  final rgba = bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  final jpeg = await _rgbaToJpegInBackground(rgba, w, h);
  return PdfDocument.createFromJpegData(jpeg, width: page.width, height: page.height, sourceName: 'flat-$id');
}

/// RGBA pixels → JPEG (quality 90) on a background isolate. Top-level, so the isolate
/// closure only captures these arguments.
Future<Uint8List> _rgbaToJpegInBackground(Uint8List rgba, int w, int h) => Isolate.run(() => img.encodeJpg(
      img.Image.fromBytes(width: w, height: h, bytes: rgba.buffer, numChannels: 4, order: img.ChannelOrder.rgba),
      quality: 90,
    ));
