import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../diary/diary_lock.dart';
import '../diary/journal_store.dart';
import 'api_client.dart';
import 'backup_crypto.dart';
import 'user_scope.dart';

/// One backup as listed by the server.
class BackupInfo {
  BackupInfo.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        createdAt = DateTime.parse(j['createdAt'] as String).toLocal(),
        sizeBytes = (j['sizeBytes'] as num).toInt(),
        photoCount = (j['photoCount'] as num?)?.toInt() ?? 0,
        entries = ((j['meta'] as Map?)?['entries'] as num?)?.toInt(),
        taskDays = ((j['meta'] as Map?)?['taskDays'] as num?)?.toInt(),
        device = j['device'] as String?;

  final int id;
  final DateTime createdAt;
  final int sizeBytes;
  final int photoCount;
  final int? entries;
  final int? taskDays;
  final String? device;
}

/// Backs up / restores the diary (journal entries + photos) and tasks.
///
/// Payload: `{ v: 1, prefs: { "journal:<id>": json, "diary:<date>": json }, images: { fileName: sha256 } }`.
/// Keys in the payload have no account prefix; on the phone they live under the
/// logged-in account's prefix ([UserScope]), so only that account's data is sent.
/// Photos are uploaded separately, once each, keyed by SHA-256 of the uploaded bytes.
///
/// With a diary password, everything is encrypted on the phone first
/// ([BackupCrypto], key from [DiaryLock.backupKey]): the payload becomes
/// `{ v: 2, enc, kdf, iter, salt, data }` around the v1 JSON, photos are
/// uploaded encrypted, and `plain` (fileName -> sha256 of the real photo) lets a
/// restore skip photos the phone already has. The server can't read any of it.
class BackupService {
  static const _api = '/api/v1/backups';

  static Future<({List<BackupInfo> backups, int usedBytes, int quotaBytes})> list() async {
    final j = await ApiClient.instance.json('GET', _api);
    final usage = j['usage'] as Map<String, dynamic>? ?? {};
    return (
      backups: [for (final b in j['backups'] as List) BackupInfo.fromJson(b as Map<String, dynamic>)],
      usedBytes: ((usage['backupBytes'] as num? ?? 0) + (usage['photoBytes'] as num? ?? 0)).toInt(),
      quotaBytes: (usage['quotaBytes'] as num? ?? 0).toInt(),
    );
  }

  /// Uploads everything; [progress] gets short status text.
  static Future<void> backupNow({void Function(String)? progress}) async {
    final api = ApiClient.instance;
    progress?.call('Reading diary and tasks…');
    await JournalStore.all(); // runs the old-notes migration first, if needed
    final prefs = await SharedPreferences.getInstance();
    final scope = await UserScope.prefix();

    final data = <String, String>{};
    var entries = 0, taskDays = 0;
    final imageNames = <String>{};
    for (final scoped in prefs.getKeys().where((k) => k.startsWith(scope))) {
      final k = scoped.substring(scope.length);
      if (!UserScope.isDataKey(k)) continue;
      final v = prefs.getString(scoped);
      if (v == null) continue;
      data[k] = v;
      if (k.startsWith('journal:')) {
        entries++;
        final images = (jsonDecode(v) as Map<String, dynamic>)['images'] as List? ?? [];
        imageNames.addAll(images.cast<String>());
      } else {
        taskDays++;
      }
    }

    // Diary password set -> encrypted backup. Its key is made when the password
    // is set or entered, so a password from an older version needs one unlock first.
    final secret = await DiaryLock.backupKey();
    if (secret == null && await DiaryLock.isEnabled()) {
      throw ApiException(0, 'backup_key_missing',
          'Open the Diary once with its password, then back up again (backups are now encrypted).');
    }
    // The bytes that go to the server for a photo.
    Future<Uint8List> upload(File f) async {
      final bytes = await f.readAsBytes();
      return secret == null ? bytes : BackupCrypto.encrypt(secret.key, bytes, deterministic: true);
    }

    // Hash every photo that still exists on the phone.
    final images = <String, String>{}; // file name -> sha256 of the uploaded bytes
    final plain = <String, String>{}; // file name -> sha256 of the photo itself
    final files = <String, File>{}; // sha256 (uploaded) -> file
    for (final name in imageNames) {
      final f = await JournalStore.imageFile(name);
      if (!await f.exists()) continue;
      final bytes = await upload(f);
      final sha = sha256.convert(bytes).toString();
      images[name] = sha;
      if (secret != null) plain[name] = sha256.convert(await f.readAsBytes()).toString();
      files[sha] = f;
    }

    if (files.isNotEmpty) {
      progress?.call('Checking photos…');
      final check = await api.json('POST', '$_api/photos/check', body: {'hashes': files.keys.toList()});
      final missing = (check['missing'] as List).cast<String>();
      for (var i = 0; i < missing.length; i++) {
        progress?.call('Uploading photo ${i + 1} of ${missing.length}…');
        await api.putBytes('$_api/photos/${missing[i]}', await upload(files[missing[i]]!));
      }
    }

    progress?.call(secret == null ? 'Saving backup…' : 'Encrypting and saving backup…');
    final inner = jsonEncode({'v': 1, 'prefs': data, 'images': images, if (secret != null) 'plain': plain});
    final payload = secret == null
        ? inner
        : jsonEncode({
            'v': 2,
            'enc': 'aes-256-gcm',
            'kdf': 'pbkdf2-sha256',
            'iter': BackupCrypto.iterations,
            'salt': base64Encode(secret.salt),
            'data': base64Encode(await BackupCrypto.encrypt(secret.key, utf8.encode(inner))),
          });
    await api.json('POST', _api, body: {
      'payload': payload,
      'encrypted': secret != null,
      'photoHashes': files.keys.toList(),
      'meta': {'entries': entries, 'taskDays': taskDays, 'photos': files.length},
      'device': Platform.operatingSystem,
      'appVersion': '1.0.0',
    });
    final p = await SharedPreferences.getInstance();
    await p.setString('account:lastBackup', DateTime.now().toIso8601String());
  }

  // ---- Sync later (server not live / no internet) ---------------------------------

  static const _kPending = 'account:pendingSync';

  /// A backup is waiting because the server couldn't be reached.
  static Future<bool> pendingSync() async =>
      (await SharedPreferences.getInstance()).getBool(_kPending) ?? false;

  static Future<void> _setPending(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kPending, v);

  /// Backs up now; if the server is offline, remembers to sync later instead of
  /// failing. Returns true when the backup reached the server.
  static Future<bool> syncNow({void Function(String)? progress}) async {
    try {
      await backupNow(progress: progress);
      await _setPending(false);
      return true;
    } on ApiException catch (e) {
      if (!e.serverOffline) rethrow;
      await _setPending(true);
      return false;
    }
  }

  /// Called when the app opens: finishes a waiting sync once the server is live.
  static Future<void> syncIfPending() async {
    final api = ApiClient.instance;
    await api.load();
    if (!api.isLoggedIn || !await pendingSync()) return;
    if (!await api.serverReachable()) return;
    try {
      await syncNow();
    } catch (_) {/* try again next time */}
  }

  static Future<DateTime?> lastBackup() async {
    final raw = (await SharedPreferences.getInstance()).getString('account:lastBackup');
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// A photo file name from a backup, or null if it isn't a plain file name
  /// (never write outside the diary's photo folder).
  static String? _safeName(String name) =>
      RegExp(r'^[A-Za-z0-9._-]{1,200}$').hasMatch(name) && !name.startsWith('.') ? name : null;

  /// Replaces the diary and tasks on this phone with backup [id].
  /// [askPassword] is called for an encrypted backup made with another diary
  /// password (e.g. on another phone); null/empty = cancelled.
  static Future<void> restore(int id,
      {void Function(String)? progress, Future<String?> Function()? askPassword}) async {
    final api = ApiClient.instance;
    progress?.call('Downloading backup…');
    final b = await api.json('GET', '$_api/$id');
    var payload = jsonDecode(b['payload'] as String) as Map<String, dynamic>;

    // Encrypted: use this phone's key if it made the backup, else ask.
    Uint8List? key;
    String? enteredPassword;
    if (payload['v'] == 2) {
      final salt = base64Decode(payload['salt'] as String);
      final local = await DiaryLock.backupKey();
      if (local != null && base64Encode(local.salt) == payload['salt']) {
        key = local.key;
      } else {
        enteredPassword = askPassword == null ? null : await askPassword();
        if (enteredPassword == null || enteredPassword.isEmpty) {
          throw ApiException(0, 'cancelled', 'This backup is encrypted: its diary password is needed to restore it.');
        }
        progress?.call('Unlocking backup…');
        key = await BackupCrypto.deriveKey(enteredPassword, salt, rounds: (payload['iter'] as num).toInt());
      }
      try {
        final inner = await BackupCrypto.decrypt(key, base64Decode(payload['data'] as String));
        payload = jsonDecode(utf8.decode(inner)) as Map<String, dynamic>;
      } on WrongBackupPassword {
        throw ApiException(0, 'wrong_password', 'Wrong diary password for this backup.');
      }
    }

    final data = (payload['prefs'] as Map).cast<String, String>();
    final images = (payload['images'] as Map? ?? {}).cast<String, String>();
    final plain = (payload['plain'] as Map? ?? {}).cast<String, String>();

    // Photos first, so a failed download leaves the current diary untouched.
    final names = images.keys.where((n) => _safeName(n) != null).toList();
    for (var i = 0; i < names.length; i++) {
      final f = await JournalStore.imageFile(names[i]);
      final want = key == null ? images[names[i]] : plain[names[i]];
      if (want != null && await f.exists() && sha256.convert(await f.readAsBytes()).toString() == want) continue;
      progress?.call('Downloading photo ${i + 1} of ${names.length}…');
      var bytes = await api.getBytes('$_api/photos/${images[names[i]]}');
      if (key != null) bytes = await BackupCrypto.decrypt(key, bytes);
      await f.writeAsBytes(bytes, flush: true);
    }

    progress?.call('Restoring…');
    final prefs = await SharedPreferences.getInstance();
    final scope = await UserScope.prefix();
    for (final k in prefs.getKeys().where((k) => k.startsWith(scope) && UserScope.isDataKey(k.substring(scope.length))).toList()) {
      await prefs.remove(k);
    }
    for (final e in data.entries) {
      if (UserScope.isDataKey(e.key)) await prefs.setString(scope + e.key, e.value);
    }
    await prefs.setBool(scope + JournalStore.migratedKey, true);

    // The diary comes back locked: no diary password on this phone yet -> use
    // the one the backup was encrypted with.
    if (enteredPassword != null && !await DiaryLock.isEnabled()) await DiaryLock.setPin(enteredPassword);
  }

  static Future<void> delete(int id) => ApiClient.instance.json('DELETE', '$_api/$id');
}
