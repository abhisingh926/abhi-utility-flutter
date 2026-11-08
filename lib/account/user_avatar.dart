import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';

/// Profile photo of the logged-in user, or their first initial when there is none.
/// Updates itself when the photo changes (AccountUser.avatarVersion).
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, this.radius = 20});

  final double radius;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AccountUser?>(
      valueListenable: ApiClient.instance.user,
      builder: (context, user, _) {
        final scheme = Theme.of(context).colorScheme;
        final label = (user?.name?.isNotEmpty == true ? user!.name! : user?.email ?? '?');
        final initial = CircleAvatar(
          radius: radius,
          backgroundColor: scheme.primaryContainer,
          child: Text(label[0].toUpperCase(),
              style: TextStyle(fontSize: radius * 0.85, color: scheme.onPrimaryContainer, fontWeight: FontWeight.bold)),
        );
        final version = user?.avatarVersion;
        if (user == null || version == null) return initial;
        return FutureBuilder<Uint8List?>(
          key: ValueKey('${user.id}:$version'),
          future: AvatarCache.load(user.id, version),
          initialData: AvatarCache.memory(user.id, version),
          builder: (context, snap) {
            final bytes = snap.data;
            if (bytes == null) return initial;
            return CircleAvatar(
              radius: radius,
              backgroundColor: scheme.primaryContainer,
              backgroundImage: MemoryImage(bytes),
            );
          },
        );
      },
    );
  }
}

/// The photo, kept in memory and on the phone so it shows offline and isn't
/// downloaded again until it changes.
class AvatarCache {
  static String? _key;
  static Uint8List? _bytes;

  static Uint8List? memory(int userId, String version) => _key == '$userId:$version' ? _bytes : null;

  static Future<File> _file(int userId, String version) async =>
      File('${(await getApplicationSupportDirectory()).path}/avatar_${userId}_$version.img');

  /// Cached copy, or downloads it. Null when it can't be loaded (e.g. offline, never cached).
  static Future<Uint8List?> load(int userId, String version) async {
    final mem = memory(userId, version);
    if (mem != null) return mem;
    try {
      final file = await _file(userId, version);
      final bytes = await file.exists() ? await file.readAsBytes() : await ApiClient.instance.getBytes('/api/v1/me/avatar');
      await remember(userId, version, bytes);
      return bytes;
    } catch (_) {
      return null; // shows the initial instead
    }
  }

  /// Stores [bytes] as the current photo and deletes older cached ones.
  static Future<void> remember(int userId, String version, Uint8List bytes) async {
    _key = '$userId:$version';
    _bytes = bytes;
    final file = await _file(userId, version);
    if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
    for (final f in file.parent.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.startsWith('avatar_') && f.path != file.path) await f.delete().catchError((_) => f);
    }
  }
}

/// Square, centre-cropped 512 px JPEG for upload, made on a background isolate.
/// Top-level on purpose: a closure made inside a widget's State method would also
/// capture the State, which can't be sent to an isolate.
Future<Uint8List> squareAvatarJpeg(Uint8List original) => Isolate.run(() => _squareJpeg(original));

/// Same as [squareAvatarJpeg], on the calling isolate (used by tests).
Uint8List squareAvatarJpegSync(Uint8List original) => _squareJpeg(original);

Uint8List _squareJpeg(Uint8List original) {
  final decoded = img.decodeImage(original);
  if (decoded == null) throw const FormatException("This photo's format isn't supported");
  final upright = img.bakeOrientation(decoded); // camera photos store rotation separately
  final size = upright.width < upright.height ? upright.width : upright.height;
  final square = img.copyCrop(
    upright,
    x: (upright.width - size) ~/ 2,
    y: (upright.height - size) ~/ 2,
    width: size,
    height: size,
  );
  final small = size > 512 ? img.copyResize(square, width: 512, height: 512, interpolation: img.Interpolation.average) : square;
  return Uint8List.fromList(img.encodeJpg(small, quality: 85));
}
