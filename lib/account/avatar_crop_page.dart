import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'user_avatar.dart';

/// Crop screen for the profile photo: drag and pinch the photo inside the circle,
/// rotate in 90° steps, then "Use photo". Pops with the cropped ≤512 px JPEG
/// (square; shown as a circle), or null when cancelled.
class AvatarCropPage extends StatefulWidget {
  const AvatarCropPage({super.key, required this.source});

  final CropSource source;

  /// Opens the crop screen for [source]; returns the JPEG to upload or null.
  static Future<Uint8List?> open(BuildContext context, CropSource source) =>
      Navigator.of(context).push<Uint8List>(MaterialPageRoute(builder: (_) => AvatarCropPage(source: source)));

  @override
  State<AvatarCropPage> createState() => _AvatarCropPageState();
}

class _AvatarCropPageState extends State<AvatarCropPage> {
  static const _maxZoom = 6.0;

  late CropSource _source = widget.source;
  late MemoryImage _image = MemoryImage(_source.bytes);

  /// Side of the square crop area on screen (logical px), set by the layout.
  double _view = 0;

  /// 1 = the photo just covers the square; up to [_maxZoom].
  double _zoom = 1;

  /// Top-left of the photo relative to the crop square (≤ 0, so it always covers it).
  Offset _offset = Offset.zero;
  bool _placed = false;

  // Gesture start values.
  double _startZoom = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  bool _busy = false;

  double get _baseScale => _view / math.min(_source.width, _source.height);
  double get _scale => _baseScale * _zoom;

  /// Keeps the photo covering the whole square.
  Offset _clamp(Offset o, double scale) {
    final w = _source.width * scale;
    final h = _source.height * scale;
    return Offset(o.dx.clamp(_view - w, 0.0), o.dy.clamp(_view - h, 0.0));
  }

  void _center() {
    _zoom = 1;
    _offset = Offset((_view - _source.width * _scale) / 2, (_view - _source.height * _scale) / 2);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _startZoom = _zoom;
    _startOffset = _offset;
    _startFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    setState(() {
      final startScale = _baseScale * _startZoom;
      _zoom = (_startZoom * d.scale).clamp(1.0, _maxZoom);
      // The photo point that was under the fingers stays under them.
      final photoPoint = (_startFocal - _startOffset) / startScale;
      _offset = _clamp(d.localFocalPoint - photoPoint * _scale, _scale);
    });
  }

  Future<void> _rotate() async {
    setState(() => _busy = true);
    final turned = await rotateCropSource(_source);
    if (!mounted) return;
    setState(() {
      _source = turned;
      _image = MemoryImage(turned.bytes);
      _center();
      _busy = false;
    });
  }

  Future<void> _use() async {
    setState(() => _busy = true);
    final s = _scale;
    final jpeg = await croppedAvatarJpeg(
      _source,
      (-_offset.dx / s).round(),
      (-_offset.dy / s).round(),
      (_view / s).round(),
    );
    if (mounted) Navigator.of(context).pop(jpeg);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Crop photo', style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            tooltip: 'Rotate',
            icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
            onPressed: _busy ? null : _rotate,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                final view = math.min(box.maxWidth, box.maxHeight) - 32;
                if (view != _view) {
                  _view = view;
                  if (!_placed) {
                    _center();
                    _placed = true;
                  } else {
                    _offset = _clamp(_offset, _scale);
                  }
                }
                return Center(
                  child: SizedBox.square(
                    dimension: view,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: _busy ? null : _onScaleStart,
                      onScaleUpdate: _busy ? null : _onScaleUpdate,
                      onDoubleTap: _busy ? null : () => setState(_center),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            left: _offset.dx,
                            top: _offset.dy,
                            width: _source.width * _scale,
                            height: _source.height * _scale,
                            child: Image(image: _image, fit: BoxFit.fill, gaplessPlayback: true),
                          ),
                          const Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _CircleMask()))),
                          if (_busy) const Center(child: CircularProgressIndicator(color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Drag to move · pinch to zoom · double-tap to reset',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                        minimumSize: const Size.fromHeight(50),
                      ),
                      onPressed: _busy ? null : () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                      onPressed: _busy ? null : _use,
                      child: const Text('Use photo'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Darkens the square outside the circle and outlines the circle (what the avatar shows).
class _CircleMask extends CustomPainter {
  const _CircleMask();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final circle = Path()..addOval(rect.deflate(1));
    final outside = Path.combine(PathOperation.difference, Path()..addRect(rect.inflate(2000)), circle);
    canvas.drawPath(outside, Paint()..color = Colors.black.withValues(alpha: 0.6));
    canvas.drawCircle(rect.center, size.width / 2 - 1, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(_CircleMask old) => false;
}
