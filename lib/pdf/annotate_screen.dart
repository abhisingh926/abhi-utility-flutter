import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'annotations.dart';

enum _Tool { pen, highlighter, text, signature }

/// Draw on one page: pen, highlighter, text and signature. Returns the edited
/// [PageAnnotations] (or null if cancelled).
class AnnotateScreen extends StatefulWidget {
  const AnnotateScreen({super.key, required this.page, required this.annotations, required this.pageLabel});

  final PdfPage page;
  final PageAnnotations annotations;
  final String pageLabel;

  @override
  State<AnnotateScreen> createState() => _AnnotateScreenState();
}

class _AnnotateScreenState extends State<AnnotateScreen> {
  static const _colors = [Colors.black, Color(0xFF1565C0), Color(0xFFD32F2F), Color(0xFF2E7D32)];
  static const _highlight = Color(0x66FFEB3B);

  late final PageAnnotations _a = widget.annotations.copy();
  ui.Image? _pageImage;
  _Tool _tool = _Tool.pen;
  Color _color = Colors.black;
  Stroke? _current;
  int _version = 0; // repaint trigger

  @override
  void initState() {
    super.initState();
    _render();
  }

  Future<void> _render() async {
    final screenW = WidgetsBinding.instance.platformDispatcher.views.first.physicalSize.width;
    final image = await renderPage(widget.page, screenW.clamp(800, 2000).toDouble());
    if (!mounted) {
      image.dispose();
      return;
    }
    setState(() => _pageImage = image);
  }

  Offset _norm(Offset local, Size size) =>
      Offset((local.dx / size.width).clamp(0, 1), (local.dy / size.height).clamp(0, 1));

  void _startStroke(Offset pos, Size size) {
    if (_tool != _Tool.pen && _tool != _Tool.highlighter) return;
    final s = _tool == _Tool.pen
        ? Stroke(color: _color, width: 0.004)
        : Stroke(color: _highlight, width: 0.025, highlighter: true);
    s.points.add(_norm(pos, size));
    _a.add(s);
    _current = s;
    setState(() => _version++);
  }

  void _extendStroke(Offset pos, Size size) {
    final s = _current;
    if (s == null) return;
    s.points.add(_norm(pos, size));
    setState(() => _version++);
  }

  Future<void> _tap(Offset pos, Size size) async {
    final at = _norm(pos, size);
    if (_tool == _Tool.text) {
      final text = await _askText();
      if (text == null || text.trim().isEmpty) return;
      setState(() {
        _a.add(TextNote(position: at, text: text.trim(), color: _color));
        _version++;
      });
    } else if (_tool == _Tool.signature) {
      final sig = await _getSignature();
      if (sig == null) return;
      // Centre the signature on the tap.
      const w = 0.35;
      final h = w / sig.aspect * size.width / size.height;
      setState(() {
        _a.add(SignatureMark(
          signature: sig,
          position: Offset((at.dx - w / 2).clamp(0, 1 - w), (at.dy - h / 2).clamp(0, 1)),
          width: w,
        ));
        _version++;
      });
    }
  }

  Future<String?> _askText() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add text'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Type here'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Add')),
        ],
      ),
    );
  }

  // ---- Signature (drawn once, remembered on this phone) ----------------------------------

  static const _sigKey = 'pdf_signature';

  Future<Signature?> _getSignature({bool forceNew = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (!forceNew) {
      final saved = prefs.getString(_sigKey);
      if (saved != null) {
        final j = jsonDecode(saved) as Map<String, dynamic>;
        return Signature(
          [
            for (final s in j['strokes'] as List)
              [for (final p in s as List) Offset((p[0] as num).toDouble(), (p[1] as num).toDouble())]
          ],
          (j['aspect'] as num).toDouble(),
        );
      }
    }
    if (!mounted) return null;
    final sig = await showDialog<Signature>(context: context, builder: (_) => const _SignaturePad());
    if (sig != null) {
      await prefs.setString(
        _sigKey,
        jsonEncode({
          'aspect': sig.aspect,
          'strokes': [
            for (final s in sig.strokes) [for (final p in s) [p.dx, p.dy]]
          ],
        }),
      );
    }
    return sig;
  }

  // ---- UI ----------------------------------------------------------------------------------

  Widget _toolButton(_Tool tool, IconData icon, String label) {
    final selected = _tool == tool;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _tool = tool),
        onLongPress: tool == _Tool.signature
            ? () async {
                await _getSignature(forceNew: true);
                setState(() => _tool = _Tool.signature);
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              Icon(icon, color: selected ? Theme.of(context).colorScheme.primary : null),
              Text(label,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected ? Theme.of(context).colorScheme.primary : null,
                    fontWeight: selected ? FontWeight.bold : null,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  String get _hint => switch (_tool) {
        _Tool.pen => 'Draw with your finger',
        _Tool.highlighter => 'Drag over text to highlight',
        _Tool.text => 'Tap where the text should go',
        _Tool.signature => 'Tap where to sign · long-press ✍ to redraw your signature',
      };

  @override
  Widget build(BuildContext context) {
    final image = _pageImage;
    return Scaffold(
      appBar: AppBar(
        title: Text('Edit ${widget.pageLabel}'),
        actions: [
          IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo),
            onPressed: () => setState(() {
              _a.undo();
              _version++;
            }),
          ),
          TextButton(onPressed: () => Navigator.pop(context, _a), child: const Text('Done')),
        ],
      ),
      backgroundColor: Colors.grey.shade800,
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.black54,
            padding: const EdgeInsets.all(6),
            child: Text(_hint, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
          ),
          Expanded(
            child: image == null
                ? const Center(child: CircularProgressIndicator())
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: AspectRatio(
                        aspectRatio: image.width / image.height,
                        child: LayoutBuilder(builder: (context, c) {
                          final size = Size(c.maxWidth, c.maxHeight);
                          return GestureDetector(
                            onPanStart: (d) => _startStroke(d.localPosition, size),
                            onPanUpdate: (d) => _extendStroke(d.localPosition, size),
                            onPanEnd: (_) => _current = null,
                            onTapUp: (d) => _tap(d.localPosition, size),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                RawImage(image: image, fit: BoxFit.fill),
                                CustomPaint(painter: _AnnotationPainter(_a, _version)),
                              ],
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
          ),
          Material(
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_tool == _Tool.pen || _tool == _Tool.text)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final c in _colors)
                            GestureDetector(
                              onTap: () => setState(() => _color = c),
                              child: Container(
                                margin: const EdgeInsets.symmetric(horizontal: 8),
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: _color == c ? Theme.of(context).colorScheme.primary : Colors.white,
                                    width: _color == c ? 3 : 1,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  Row(
                    children: [
                      _toolButton(_Tool.pen, Icons.edit, 'Pen'),
                      _toolButton(_Tool.highlighter, Icons.highlight, 'Highlight'),
                      _toolButton(_Tool.text, Icons.text_fields, 'Text'),
                      _toolButton(_Tool.signature, Icons.draw, 'Sign'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pageImage?.dispose();
    super.dispose();
  }
}

class _AnnotationPainter extends CustomPainter {
  _AnnotationPainter(this.a, this.version);
  final PageAnnotations a;
  final int version;

  @override
  void paint(Canvas canvas, Size size) => paintAnnotations(canvas, size, a);

  @override
  bool shouldRepaint(_AnnotationPainter old) => old.version != version || old.a != a;
}

/// Draw a signature with your finger.
class _SignaturePad extends StatefulWidget {
  const _SignaturePad();

  @override
  State<_SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<_SignaturePad> {
  static const _aspect = 3.0;
  final List<List<Offset>> _strokes = [];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Draw your signature'),
      contentPadding: const EdgeInsets.all(16),
      content: SizedBox(
        width: 320,
        child: AspectRatio(
          aspectRatio: _aspect,
          child: LayoutBuilder(builder: (context, c) {
            Offset norm(Offset p) =>
                Offset((p.dx / c.maxWidth).clamp(0, 1), (p.dy / c.maxHeight).clamp(0, 1));
            return GestureDetector(
              onPanStart: (d) => setState(() => _strokes.add([norm(d.localPosition)])),
              onPanUpdate: (d) => setState(() => _strokes.last.add(norm(d.localPosition))),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: CustomPaint(
                  painter: _SignaturePainter(_strokes, _strokes.fold(0, (n, s) => n + s.length)),
                  child: const SizedBox.expand(),
                ),
              ),
            );
          }),
        ),
      ),
      actions: [
        TextButton(onPressed: () => setState(_strokes.clear), child: const Text('Clear')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _strokes.isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    // Strokes are stored relative to the box: x 0..1, y 0..1.
                    Signature([for (final s in _strokes) List.of(s)], _aspect),
                  ),
          child: const Text('Use'),
        ),
      ],
    );
  }
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.strokes, this.points);
  final List<List<Offset>> strokes;
  final int points;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF0D1B6E)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final s in strokes) {
      if (s.isEmpty) continue;
      final path = Path()..moveTo(s.first.dx * size.width, s.first.dy * size.height);
      for (final p in s.skip(1)) {
        path.lineTo(p.dx * size.width, p.dy * size.height);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_SignaturePainter old) => old.points != points;
}
