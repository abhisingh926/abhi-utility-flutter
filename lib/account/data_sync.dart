import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../diary/diary_lock.dart';
import '../diary/diary_store.dart';
import '../diary/journal_store.dart';
import 'api_client.dart';
import 'backup_crypto.dart';
import 'user_scope.dart';

/// Keeps a live copy of tasks, diary entries and reel stats on the server
/// (`/api/v1/sync`), per account, for the website / other devices.
///
/// The phone is the source. Each sync sends only what changed since the last
/// one: a hash of every task day / entry / reel day that was sent is kept per
/// account (`<account>:sync:sent`), so edits, new items and deletions are found
/// by comparing. Runs on app start, resume and pause (see main.dart).
///
/// Diary entries are encrypted on the phone when a diary password is set (same
/// key as backups), so the server only stores sealed text.
class DataSync {
  DataSync._();

  static const _reelsChannel = MethodChannel('abhi_utility/reels');
  static const _api = '/api/v1/sync';

  /// Keep each request well under the server's 5 MB limit.
  static const _maxBatchBytes = 3 * 1024 * 1024;
  static const _maxBatchItems = 400;
  static const reelDays = 90;

  static const _kSent = 'sync:sent';
  static const _kPhotoSha = 'sync:photoSha';
  static const _kReelsFrom = 'sync:reelsFrom';
  static const _kLastSync = 'sync:last';

  /// Device-wide: the account the phone's reel stats were last sent to.
  static const _kReelsOwner = 'sync:reelsOwner';

  static Future<void>? _running;
  static DateTime? _lastRun;

  /// Last successful sync of this account (null = never), for status text.
  static final lastSynced = ValueNotifier<DateTime?>(null);

  /// The diary has a password but its key isn't cached yet: entries wait until
  /// the diary is opened once with the password.
  static final diaryWaiting = ValueNotifier<bool>(false);

  /// Syncs if logged in. Skipped when the last run was under [minGap] ago.
  /// Never throws (offline = try again next time).
  static Future<void> run({Duration minGap = const Duration(seconds: 20)}) {
    final last = _lastRun;
    if (_running != null) return _running!;
    if (last != null && DateTime.now().difference(last) < minGap) return Future.value();
    return _running = _run().catchError((Object e) {
      debugPrint('DataSync: $e');
    }).whenComplete(() {
      _lastRun = DateTime.now();
      _running = null;
    });
  }

  static Future<void> _run() async {
    final api = ApiClient.instance;
    await api.load();
    final user = api.user.value;
    if (user == null || !api.isLoggedIn) return;

    final prefs = await SharedPreferences.getInstance();
    final scope = await UserScope.prefix();
    if (scope == UserScope.localPrefix) return;
    final last = prefs.getString(scope + _kLastSync);
    lastSynced.value = last == null ? null : DateTime.tryParse(last);

    final sent = _readMap(prefs, scope + _kSent);
    final batch = _Batch();

    Future<void> flush() async {
      if (batch.isEmpty) return;
      await api.json('POST', _api, body: batch.body());
      sent
        ..removeWhere((k, _) => batch.removedKeys.contains(k))
        ..addAll(batch.sentHashes);
      await prefs.setString(scope + _kSent, jsonEncode(sent));
      batch.clear();
    }

    Future<void> add(void Function() put, int bytes) async {
      if (!batch.isEmpty && (batch.bytes + bytes > _maxBatchBytes || batch.items >= _maxBatchItems)) await flush();
      put();
      batch.bytes += bytes;
      batch.items++;
    }

    // ---- Tasks: one record per day -----------------------------------------------
    final taskPrefix = '${scope}diary:';
    final taskDays = <String>{};
    for (final k in prefs.getKeys().where((k) => k.startsWith(taskPrefix))) {
      final dayKey = k.substring(taskPrefix.length);
      final raw = prefs.getString(k);
      if (raw == null || DateTime.tryParse(dayKey) == null) continue;
      final tasks = [for (final t in DiaryDay.fromJson(jsonDecode(raw) as Map<String, dynamic>).tasks) t.toJson()];
      if (tasks.isEmpty) continue;
      taskDays.add(dayKey);
      final json = jsonEncode(tasks);
      final h = _hash(json);
      if (sent['t:$dayKey'] == h) continue;
      await add(() {
        batch.tasks.add({'day': dayKey, 'tasks': tasks});
        batch.sentHashes['t:$dayKey'] = h;
      }, json.length);
    }
    // Days that were sent before and are now empty: clear them on the server.
    for (final k in sent.keys.where((k) => k.startsWith('t:')).toList()) {
      final dayKey = k.substring(2);
      if (taskDays.contains(dayKey)) continue;
      await add(() {
        batch.tasks.add({'day': dayKey, 'tasks': <Object>[]});
        batch.removedKeys.add(k);
      }, 40);
    }

    // ---- Diary entries -----------------------------------------------------------
    final secret = await DiaryLock.backupKey();
    final waiting = secret == null && await DiaryLock.isEnabled();
    diaryWaiting.value = waiting;
    if (!waiting) {
      // Hashes include the key's salt: a new diary password re-sends every entry.
      final keyTag = secret == null ? 'plain' : base64Encode(secret.salt);
      final photoSha = _readMap(prefs, scope + _kPhotoSha);
      var photosChanged = false;
      var photosBlocked = false; // backup storage is Pro-only / full: text still syncs

      Future<String?> photo(String name) async {
        final cacheKey = '$keyTag|$name';
        final f = await JournalStore.imageFile(name);
        if (!await f.exists()) return null;
        var sha = photoSha[cacheKey];
        Uint8List? bytes;
        if (sha == null) {
          bytes = await _photoBytes(f, secret?.key);
          sha = sha256.convert(bytes).toString();
          photoSha[cacheKey] = sha;
          photosChanged = true;
        }
        if (photosBlocked) return null;
        try {
          final check = await api.json('POST', '/api/v1/backups/photos/check', body: {
            'hashes': [sha]
          });
          if ((check['missing'] as List).isNotEmpty) {
            await api.putBytes('/api/v1/backups/photos/$sha', bytes ?? await _photoBytes(f, secret?.key));
          }
          return sha;
        } on ApiException catch (e) {
          if (e.status == 402 || e.status == 413) {
            photosBlocked = true;
            return null;
          }
          rethrow;
        }
      }

      final ids = <String>{};
      for (final e in await JournalStore.all()) {
        if (e.isEmpty) continue;
        ids.add(e.id);
        final plain = jsonEncode(e.toJson());
        final h = _hash('$keyTag|$plain');
        if (sent['j:${e.id}'] == h) continue;
        final photos = <String>[];
        var allPhotos = true;
        for (final name in e.images) {
          final sha = await photo(name);
          if (sha == null) {
            allPhotos = false;
          } else {
            photos.add(sha);
          }
        }
        final item = <String, Object?>{'id': e.id, 'date': e.date.toIso8601String(), 'photos': photos};
        if (secret == null) {
          item['text'] = e.text;
          if (e.mood != null) item['mood'] = e.mood;
        } else {
          item['encryptedData'] = await _seal(secret, {'text': e.text, 'mood': e.mood});
        }
        final size = ((item['text'] ?? item['encryptedData']) as String).length + 200;
        await add(() {
          batch.journal.add(item);
          // Photos left out (storage full / Pro only): try them again next time.
          batch.sentHashes['j:${e.id}'] = allPhotos ? h : '$h~';
        }, size);
      }
      for (final k in sent.keys.where((k) => k.startsWith('j:')).toList()) {
        final id = k.substring(2);
        if (ids.contains(id)) continue;
        await add(() {
          batch.journalDeleted.add(id);
          batch.removedKeys.add(k);
        }, 60);
      }
      if (photosChanged) await prefs.setString(scope + _kPhotoSha, jsonEncode(photoSha));
    }

    // ---- Reel stats (Android only; stored per phone, not per account) -------------
    if (Platform.isAndroid) {
      // Another account already got this phone's reels: send only days from now on.
      var from = prefs.getString(scope + _kReelsFrom);
      if (from == null) {
        final owner = prefs.getInt(_kReelsOwner);
        from = owner == null || owner == user.id ? '' : DiaryStore.key(DateTime.now());
        await prefs.setString(scope + _kReelsFrom, from);
      }
      await prefs.setInt(_kReelsOwner, user.id);

      final counts = await _stats('stats');
      final seconds = await _stats('timeStats');
      for (final day in {...counts.keys, ...seconds.keys}) {
        if (day.compareTo(from) < 0) continue;
        final c = counts[day] ?? const {}, s = seconds[day] ?? const {};
        final apps = <String, Map<String, int>>{
          for (final app in {...c.keys, ...s.keys}) app: {'reels': c[app] ?? 0, 'seconds': s[app] ?? 0},
        };
        if (apps.values.every((v) => v['reels'] == 0 && v['seconds'] == 0)) continue;
        final json = jsonEncode(apps);
        final h = _hash(json);
        if (sent['r:$day'] == h) continue;
        await add(() {
          batch.reels.add({'day': day, 'apps': apps});
          batch.sentHashes['r:$day'] = h;
        }, json.length);
      }
    }

    await flush();
    final now = DateTime.now();
    await prefs.setString(scope + _kLastSync, now.toIso8601String());
    lastSynced.value = now;
  }

  static Future<Map<String, Map<String, int>>> _stats(String method) async {
    try {
      final raw = await _reelsChannel.invokeMapMethod<String, dynamic>(method, {'days': reelDays}) ?? {};
      return {
        for (final e in raw.entries)
          e.key: {for (final a in (e.value as Map).entries) a.key as String: (a.value as num).toInt()},
      };
    } on MissingPluginException {
      return {};
    }
  }

  /// The bytes uploaded for a photo: encrypted the same way as backups (so the
  /// server stores each photo once for both).
  static Future<Uint8List> _photoBytes(File f, Uint8List? key) async {
    final bytes = await f.readAsBytes();
    return key == null ? bytes : BackupCrypto.encrypt(key, bytes, deterministic: true);
  }

  /// Text + mood sealed with the diary key (same envelope as encrypted backups).
  static Future<String> _seal(({Uint8List key, Uint8List salt}) secret, Map<String, Object?> data) async =>
      jsonEncode({
        'v': 2,
        'enc': 'aes-256-gcm',
        'kdf': 'pbkdf2-sha256',
        'iter': BackupCrypto.iterations,
        'salt': base64Encode(secret.salt),
        'data': base64Encode(await BackupCrypto.encrypt(secret.key, utf8.encode(jsonEncode(data)))),
      });

  static String _hash(String s) => sha256.convert(utf8.encode(s)).toString().substring(0, 32);

  static Map<String, String> _readMap(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }
}

/// One POST /api/v1/sync request being built.
class _Batch {
  final tasks = <Map<String, Object?>>[];
  final journal = <Map<String, Object?>>[];
  final journalDeleted = <String>[];
  final reels = <Map<String, Object?>>[];

  /// What to remember once the request succeeds.
  final sentHashes = <String, String>{};
  final removedKeys = <String>{};
  int bytes = 0;
  int items = 0;

  bool get isEmpty => items == 0;

  Map<String, Object?> body() => {
        if (tasks.isNotEmpty) 'tasks': tasks,
        if (journal.isNotEmpty) 'journal': journal,
        if (journalDeleted.isNotEmpty) 'journalDeleted': journalDeleted,
        if (reels.isNotEmpty) 'reels': reels,
      };

  void clear() {
    tasks.clear();
    journal.clear();
    journalDeleted.clear();
    reels.clear();
    sentHashes.clear();
    removedKeys.clear();
    bytes = 0;
    items = 0;
  }
}
