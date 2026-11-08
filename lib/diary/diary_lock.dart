import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/backup_crypto.dart';

/// Optional password for the Diary (its own password; the App Lock one opens it too).
/// Only a salted SHA-256 hash is stored.
class DiaryLock {
  static const _hashKey = 'diary_pin_hash';
  static const _saltKey = 'diary_pin_salt';

  /// Diary unlocked (until the app is left or someone taps a lock button).
  /// Pages only ask when they are actually opened.
  static final unlocked = ValueNotifier<bool>(false);

  /// App Lock unlocked. Only the App Lock password (or its fingerprint) sets
  /// this: the Diary password can be created by anyone, so it must never open
  /// App Lock or uninstall protection (the parent's settings).
  static final appLockUnlocked = ValueNotifier<bool>(false);

  /// App Lock password / fingerprint: opens App Lock and the Diary.
  static void unlockAll() {
    appLockUnlocked.value = true;
    unlocked.value = true;
    _setPrivate(true);
  }

  /// Diary password / fingerprint: opens only the Diary.
  static void unlockDiary() {
    unlocked.value = true;
    _setPrivate(true);
  }

  // ---- Recent apps thumbnail ------------------------------------------------------------
  // While the Diary or App Lock is open, Android's Recents screen must not show
  // a picture of it. Turned off again on the next resume once locked (not at the
  // moment of locking: the thumbnail is taken as the app leaves, before the
  // lock screen is drawn).

  static bool _private = false;

  static void _setPrivate(bool on) {
    if (_private == on) return;
    _private = on;
    const MethodChannel('abhi_utility/app').invokeMethod('setPrivate', {'on': on}).catchError((_) {});
  }

  /// Changes when the Diary and App Lock lock again (app left, lock button, restore).
  static final relock = ValueNotifier<int>(0);

  static void lockNow() {
    unlocked.value = false;
    appLockUnlocked.value = false;
    relock.value++;
  }

  /// True while the gallery/camera is open from the diary editor: leaving the
  /// app for that must not lock the diary.
  static bool pickingPhoto = false;

  /// True while Abhi Utility itself opens a system screen (e.g. "Activate device admin").
  static bool openingSystemScreen = false;

  /// Away longer than this for the photo picker / a system screen: the user
  /// probably left from there (Home, Recents), so lock when the app comes back.
  static const maxAwayForPicker = Duration(minutes: 3);
  static DateTime? _awaySince;

  /// The app went to the background: lock, unless we sent the user there ourselves.
  static void onAppPaused() {
    if (!pickingPhoto && !openingSystemScreen) {
      lockNow();
    } else {
      _awaySince ??= DateTime.now();
    }
  }

  /// The app is back in front.
  static void onAppResumed() {
    final since = _awaySince;
    _awaySince = null;
    if (since != null && DateTime.now().difference(since) > maxAwayForPicker) lockNow();
    if (!unlocked.value && !appLockUnlocked.value) _setPrivate(false);
  }

  static const _appLock = MethodChannel('abhi_utility/applock');

  /// The App Lock password (never the Diary one).
  static Future<bool> checkAppLockPassword(String pin) async {
    try {
      return await _appLock.invokeMethod<bool>('checkPin', {'pin': pin}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Diary lock screen: the Diary password opens the Diary; the App Lock
  /// password opens both. Returns false for a wrong password.
  static Future<bool> unlockDiaryWith(String pin) async {
    if (await isEnabled() && await check(pin)) { // check() is true when no diary password
      unlockDiary();
      // Diary password set before encrypted backups existed: make the key now.
      if (await backupKey() == null) unawaited(_cacheBackupKey(pin).catchError((_) {}));
      return true;
    }
    if (await checkAppLockPassword(pin)) {
      unlockAll();
      return true;
    }
    return false;
  }

  static Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance()).containsKey(_hashKey);

  static Future<void> setPin(String pin) async {
    final rnd = Random.secure();
    final salt = base64Encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_saltKey, salt);
    await prefs.setString(_hashKey, _hash(salt, pin));
    await _cacheBackupKey(pin);
  }

  // ---- Backup encryption key -------------------------------------------------------------
  // Cloud backups are encrypted with a key made from the diary password. The key
  // is kept on this phone only (Android backup is off), so automatic backups
  // don't have to ask for the password. No diary password = no encryption.

  static const _bkKey = 'diary_backup_key';
  static const _bkSalt = 'diary_backup_salt';

  static Future<void> _cacheBackupKey(String pin) async {
    final salt = BackupCrypto.newSalt();
    final key = await BackupCrypto.deriveKey(pin, salt);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bkSalt, base64Encode(salt));
    await prefs.setString(_bkKey, base64Encode(key));
  }

  /// The key (and its salt) for encrypting backups, or null when not set up.
  static Future<({Uint8List key, Uint8List salt})?> backupKey() async {
    final prefs = await SharedPreferences.getInstance();
    final k = prefs.getString(_bkKey), s = prefs.getString(_bkSalt);
    if (k == null || s == null || !prefs.containsKey(_hashKey)) return null;
    return (key: base64Decode(k), salt: base64Decode(s));
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
    await prefs.remove(_bkKey);
    await prefs.remove(_bkSalt);
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
