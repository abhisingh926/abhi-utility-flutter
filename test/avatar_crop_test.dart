import 'dart:typed_data';

import 'package:abhi_utility/account/avatar_crop_page.dart';
import 'package:abhi_utility/account/user_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 800×400 photo: left half red, right half blue.
Uint8List redBlue() {
  final im = img.Image(width: 800, height: 400);
  for (var y = 0; y < 400; y++) {
    for (var x = 0; x < 800; x++) {
      im.setPixelRgb(x, y, x < 400 ? 255 : 0, 0, x < 400 ? 0 : 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: 95));
}

/// Average colour of a JPEG as (r, b).
(int, int) redBlueOf(Uint8List jpeg) {
  final im = img.decodeJpg(jpeg)!;
  var r = 0, b = 0;
  for (final p in im) {
    r += p.r.toInt();
    b += p.b.toInt();
  }
  final n = im.width * im.height;
  return (r ~/ n, b ~/ n);
}

void main() {
  test('crop helpers: prepare, crop a square, rotate', () async {
    final src = await prepareCropSource(redBlue());
    expect((src.width, src.height), (800, 400));
    final left = await croppedAvatarJpeg(src, 0, 0, 400);
    final (r, b) = redBlueOf(left);
    expect(r, greaterThan(200));
    expect(b, lessThan(60));
    expect(img.decodeJpg(left)!.width, 400);
    final turned = await rotateCropSource(src);
    expect((turned.width, turned.height), (400, 800));
    // Clockwise: the left (red) half is now on top.
    final (tr, tb) = redBlueOf(await croppedAvatarJpeg(turned, 0, 0, 400));
    expect(tr, greaterThan(200));
    expect(tb, lessThan(60));
  });

  for (final (name, drag, wantRed) in [('drag right -> left (red) half', 600.0, true), ('drag left -> right (blue) half', -600.0, false)]) {
    testWidgets('crop screen: $name', (tester) async {
      final src = await tester.runAsync(() => prepareCropSource(redBlue()));
      Uint8List? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => result = await AvatarCropPage.open(context, src!),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(GestureDetector).first, Offset(drag, 0));
      await tester.pump();
      await tester.tap(find.text('Use photo'));
      // The crop runs in an isolate: let it finish for real.
      for (var i = 0; i < 50 && result == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pumpAndSettle(const Duration(milliseconds: 100)); // let gesture timers finish
      expect(result, isNotNull);
      final (r, b) = redBlueOf(result!);
      if (wantRed) {
        expect(r, greaterThan(200), reason: 'r=$r b=$b');
      } else {
        expect(b, greaterThan(200), reason: 'r=$r b=$b');
      }
    });
  }
}
