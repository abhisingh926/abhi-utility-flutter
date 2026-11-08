import 'dart:math';

import 'package:flutter/services.dart';

/// Thrown when an encrypted backup can't be opened with the given password.
class WrongBackupPassword implements Exception {
  @override
  String toString() => 'Wrong diary password for this backup';
}

/// AES-256-GCM + PBKDF2 for diary backups (runs natively: BackupCrypto.kt).
class BackupCrypto {
  static const _ch = MethodChannel('abhi_utility/crypto');

  /// PBKDF2 rounds: slow on purpose, because a diary password is short.
  static const iterations = 600000;

  static Uint8List newSalt() {
    final rnd = Random.secure();
    return Uint8List.fromList(List<int>.generate(16, (_) => rnd.nextInt(256)));
  }

  static Future<Uint8List> deriveKey(String password, Uint8List salt, {int rounds = iterations}) async =>
      (await _ch.invokeMethod<Uint8List>('deriveKey', {'password': password, 'salt': salt, 'iterations': rounds}))!;

  /// [deterministic]: same input -> same output (photos, so each is uploaded once).
  static Future<Uint8List> encrypt(Uint8List key, Uint8List data, {bool deterministic = false}) async =>
      (await _ch.invokeMethod<Uint8List>('encrypt', {'key': key, 'data': data, 'deterministic': deterministic}))!;

  static Future<Uint8List> decrypt(Uint8List key, Uint8List data) async {
    try {
      return (await _ch.invokeMethod<Uint8List>('decrypt', {'key': key, 'data': data}))!;
    } on PlatformException catch (e) {
      if (e.code == 'WRONG_KEY') throw WrongBackupPassword();
      rethrow;
    }
  }
}
