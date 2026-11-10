import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Chat-wallpaper style background: the app's own tool icons, small and faint,
/// scattered over the page colour. Behind every page of the main app (see
/// [PatternedPageTransitionsBuilder]); cards, app bars and the bottom bar stay solid.
///
/// One tile is drawn once per colour and repeated with an image shader, so it costs
/// next to nothing while scrolling.
class PatternBackground extends StatelessWidget {
  const PatternBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return CustomPaint(
      painter: _PatternPainter(
        background: scheme.surface,
        // Faint enough to read text over it; a touch stronger in dark mode, where it fades more.
        ink: scheme.primary.withValues(alpha: dark ? 0.10 : 0.09),
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      ),
      child: child,
    );
  }
}

/// Icons from the app's own tools (SOS, App Lock, PDF, Diary, Downloader, Reels…).
const _icons = <IconData>[
  Icons.sos_outlined,
  Icons.lock_outline,
  Icons.picture_as_pdf_outlined,
  Icons.menu_book_outlined,
  Icons.download_outlined,
  Icons.slow_motion_video,
  Icons.flashlight_on_outlined,
  Icons.checklist,
  Icons.folder_zip_outlined,
  Icons.table_chart_outlined,
  Icons.shield_outlined,
  Icons.location_on_outlined,
  Icons.phone_outlined,
  Icons.star_border_rounded,
  Icons.favorite_border_rounded,
  Icons.bolt_outlined,
  Icons.camera_alt_outlined,
  Icons.description_outlined,
];

class _PatternPainter extends CustomPainter {
  _PatternPainter({required this.background, required this.ink, required this.devicePixelRatio});

  final Color background;
  final Color ink;
  final double devicePixelRatio;

  /// Tile size in logical pixels; the pattern repeats every [_tile] × [_tile].
  static const double _tile = 240;

  /// Cached tile images, one per (ink colour, pixel ratio).
  static final Map<(int, double), ui.Image> _cache = {};

  ui.Image _tileImage() {
    final key = (ink.toARGB32(), devicePixelRatio);
    final cached = _cache[key];
    if (cached != null) return cached;
    if (_cache.length > 4) _cache.clear(); // light + dark (+ a ratio change) is all that's needed

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(devicePixelRatio);
    // 4 × 4 grid with a fixed jitter, so it looks scattered but never clumps.
    final random = math.Random(7);
    const cells = 4;
    const cell = _tile / cells;
    var n = 0;
    for (var row = 0; row < cells; row++) {
      for (var col = 0; col < cells; col++) {
        final icon = _icons[(n * 7 + row) % _icons.length];
        n++;
        final size = 20.0 + random.nextDouble() * 8; // 20–28 px
        final dx = col * cell + cell / 2 + (random.nextDouble() - 0.5) * cell * 0.45 + (row.isOdd ? cell / 2 : 0);
        final dy = row * cell + cell / 2 + (random.nextDouble() - 0.5) * cell * 0.45;
        final angle = (random.nextDouble() - 0.5) * 0.9; // about ±25°
        // Draw each icon at its spot, and again one tile over where it crosses an edge,
        // so the repeat has no seams.
        for (final ox in const [-_tile, 0.0, _tile]) {
          for (final oy in const [-_tile, 0.0, _tile]) {
            final x = dx + ox;
            final y = dy + oy;
            if (x < -size || x > _tile + size || y < -size || y > _tile + size) continue;
            _drawIcon(canvas, icon, Offset(x, y), size, angle);
          }
        }
      }
    }
    final px = (_tile * devicePixelRatio).round();
    final image = recorder.endRecording().toImageSync(px, px);
    _cache[key] = image;
    return image;
  }

  void _drawIcon(Canvas canvas, IconData icon, Offset center, double size, double angle) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: size,
          color: ink,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..rotate(angle);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
    tp.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = background);
    final scale = 1 / devicePixelRatio;
    final shader = ImageShader(
      _tileImage(),
      TileMode.repeated,
      TileMode.repeated,
      (Matrix4.identity()..scaleByDouble(scale, scale, 1, 1)).storage,
    );
    canvas.drawRect(rect, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_PatternPainter old) =>
      old.background != background || old.ink != ink || old.devicePixelRatio != devicePixelRatio;
}

/// Wraps the platform's normal page transition so every page (route) of the main app
/// sits on its own [PatternBackground]. Each page is opaque, so pages don't show
/// through each other while sliding in and out.
class PatternedPageTransitionsBuilder extends PageTransitionsBuilder {
  const PatternedPageTransitionsBuilder(this.base);

  final PageTransitionsBuilder base;

  @override
  DelegatedTransitionBuilder? get delegatedTransition => base.delegatedTransition;

  @override
  Duration get transitionDuration => base.transitionDuration;

  @override
  Duration get reverseTransitionDuration => base.reverseTransitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      base.buildTransitions(route, context, animation, secondaryAnimation, PatternBackground(child: child));
}
