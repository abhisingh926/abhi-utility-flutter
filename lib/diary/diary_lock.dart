import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Optional password for the Diary (separate from the App Lock password).
/// Only a salted SHA-256 hash is stored.
class DiaryLock {
  static const _hashKey = 'diary_pin_hash';
  static const _saltKey = 'diary_pin_salt';

  /// Changes when the diary should lock again (e.g. the user left the Diary tab).
  static final relock = ValueNotifier<int>(0);

  static void lockNow() => relock.value++;

  /// True while the gallery/camera is open from the diary editor: leaving the
  /// app for that must not lock the diary.
  static bool pickingPhoto = false;

  static Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance()).containsKey(_hashKey);

  static Future<void> setPin(String pin) async {
    final rnd = Random.secure();
    final salt = base64Encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_saltKey, salt);
    await prefs.setString(_hashKey, _hash(salt, pin));
  }

  static Future<bool> check(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = prefs.getString(_saltKey);
    final hash = prefs.getString(_hashKey);
    if (salt == null || hash == null) return true;
    return _hash(salt, pin) == hash;
  }

  static Future<void> remove() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_hashKey);
    await prefs.remove(_saltKey);
    await prefs.remove(_bioKey);
  }

  static String _hash(String salt, String pin) => sha256.convert(utf8.encode('$salt:$pin')).toString();

  // ---- Fingerprint ---------------------------------------------------------------------

  static const _bioKey = 'diary_biometric';
  static final _auth = LocalAuthentication();

  /// True if the phone has a fingerprint (or face) enrolled.
  static Future<bool> biometricAvailable() async {
    try {
      return await _auth.canCheckBiometrics && (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> biometricEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_bioKey) ?? false;

  static Future<void> setBiometricEnabled(bool on) async =>
      (await SharedPreferences.getInstance()).setBool(_bioKey, on);

  /// Shows the fingerprint prompt. Returns true when the user was recognised.
  static Future<bool> authenticate({String reason = 'Unlock your diary'}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true, // the diary password is the fallback, not the phone PIN
      );
    } catch (_) {
      return false; // cancelled, too many attempts, not available…
    }
  }
}
