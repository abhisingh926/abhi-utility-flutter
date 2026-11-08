import 'dart:typed_data';

import 'package:abhi_utility/account/user_avatar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('crops to a centred square and shrinks big photos to 512 px', () {
    final wide = img.Image(width: 1600, height: 900);
    final out = img.decodeJpg(squareAvatarJpegSync(Uint8List.fromList(img.encodePng(wide))))!;
    expect(out.width, 512);
    expect(out.height, 512);
  });

  test('keeps small photos at their size (still square, JPEG)', () {
    final tall = img.Image(width: 200, height: 300);
    final bytes = squareAvatarJpegSync(Uint8List.fromList(img.encodePng(tall)));
    expect(bytes.sublist(0, 3), [0xff, 0xd8, 0xff]); // JPEG, accepted by the backend
    final out = img.decodeJpg(bytes)!;
    expect((out.width, out.height), (200, 200));
  });

  test('rejects data that is not an image', () {
    expect(() => squareAvatarJpegSync(Uint8List.fromList([1, 2, 3, 4])), throwsFormatException);
  });
}
