import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../diary/journal_store.dart';
import 'api_client.dart';

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
/// Photos are uploaded separately, once each, keyed by SHA-256.
class BackupService {
  static const _api = '/api/v1/backups';
  static bool _isOurKey(String k) => k.startsWith('journal:') || k.startsWith('diary:');

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

    final data = <String, String>{};
    var entries = 0, taskDays = 0;
    final imageNames = <String>{};
    for (final k in prefs.getKeys().where(_isOurKey)) {
      final v = prefs.getString(k);
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

    // Hash every photo that still exists on the phone.
    final images = <String, String>{}; // file name -> sha256
    final files = <String, File>{}; // sha256 -> file
    for (final name in imageNames) {
      final f = await JournalStore.imageFile(name);
      if (!await f.exists()) continue;
      final sha = sha256.convert(await f.readAsBytes()).toString();
      images[name] = sha;
      files[sha] = f;
    }

    if (files.isNotEmpty) {
      progress?.call('Checking photos…');
      final check = await api.json('POST', '$_api/photos/check', body: {'hashes': files.keys.toList()});
      final missing = (check['missing'] as List).cast<String>();
      for (var i = 0; i < missing.length; i++) {
        progress?.call('Uploading photo ${i + 1} of ${missing.length}…');
        await api.putBytes('$_api/photos/${missing[i]}', await files[missing[i]]!.readAsBytes());
      }
    }

    progress?.call('Saving backup…');
    await api.json('POST', _api, body: {
      'payload': jsonEncode({'v': 1, 'prefs': data, 'images': images}),
      'encrypted': false,
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

  /// Replaces the diary and tasks on this phone with backup [id].
  static Future<void> restore(int id, {void Function(String)? progress}) async {
    final api = ApiClient.instance;
    progress?.call('Downloading backup…');
    final b = await api.json('GET', '$_api/$id');
    final payload = jsonDecode(b['payload'] as String) as Map<String, dynamic>;
    final data = (payload['prefs'] as Map).cast<String, String>();
    final images = (payload['images'] as Map? ?? {}).cast<String, String>();

    // Photos first, so a failed download leaves the current diary untouched.
    final names = images.keys.toList();
    for (var i = 0; i < names.length; i++) {
      final f = await JournalStore.imageFile(names[i]);
      if (await f.exists() && sha256.convert(await f.readAsBytes()).toString() == images[names[i]]) continue;
      progress?.call('Downloading photo ${i + 1} of ${names.length}…');
      await f.writeAsBytes(await api.getBytes('$_api/photos/${images[names[i]]}'), flush: true);
    }

    progress?.call('Restoring…');
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys().where(_isOurKey).toList()) {
      await prefs.remove(k);
    }
    for (final e in data.entries) {
      await prefs.setString(e.key, e.value);
    }
    await prefs.setBool('journal_migrated_v1', true);
  }

  static Future<void> delete(int id) => ApiClient.instance.json('DELETE', '$_api/$id');
}
