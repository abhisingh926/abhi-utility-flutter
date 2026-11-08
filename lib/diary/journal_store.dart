import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/user_scope.dart';
import 'diary_store.dart';

/// One diary (journal) entry: text, mood and photos.
class JournalEntry {
  JournalEntry({
    required this.id,
    required this.date,
    this.text = '',
    this.mood,
    List<String>? images,
  }) : images = images ?? [];

  JournalEntry.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        date = DateTime.parse(j['date'] as String),
        text = j['text'] as String? ?? '',
        mood = j['mood'] as String?,
        images = [for (final i in (j['images'] as List? ?? [])) i as String];

  final String id;
  DateTime date;
  String text;
  String? mood;

  /// File names inside [JournalStore.imagesDir].
  final List<String> images;

  bool get isEmpty => text.trim().isEmpty && images.isEmpty && mood == null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'text': text,
        if (mood != null) 'mood': mood,
        'images': images,
      };
}

/// Diary entries in SharedPreferences (key `<account>:journal:<id>`, see [UserScope]);
/// photos as files in the app's private folder (kept even if deleted from the gallery).
/// Photo file names are unique, and only the account's own entries point to them.
class JournalStore {
  static const _kind = 'journal:';
  static const migratedKey = 'journal_migrated_v1';
  static Directory? _dir;

  static Future<Directory> imagesDir() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    return _dir = await Directory('${docs.path}/diary_images').create(recursive: true);
  }

  static Future<File> imageFile(String name) async => File('${(await imagesDir()).path}/$name');

  /// Copies a picked photo into the diary folder; returns its file name.
  static Future<String> addImage(String sourcePath) async {
    final ext = sourcePath.contains('.') ? sourcePath.substring(sourcePath.lastIndexOf('.')) : '.jpg';
    final name = '${DateTime.now().microsecondsSinceEpoch}$ext';
    await File(sourcePath).copy((await imageFile(name)).path);
    return name;
  }

  static Future<void> deleteImage(String name) async {
    final f = await imageFile(name);
    if (await f.exists()) await f.delete();
  }

  /// All entries, newest first.
  static Future<List<JournalEntry>> all() async {
    final prefs = await SharedPreferences.getInstance();
    final scope = await UserScope.prefix();
    await _migrateOldNotes(prefs, scope);
    final entries = [
      for (final k in prefs.getKeys().where((k) => k.startsWith(scope + _kind)))
        JournalEntry.fromJson(jsonDecode(prefs.getString(k)!) as Map<String, dynamic>),
    ]..sort((a, b) => b.date.compareTo(a.date));
    return entries;
  }

  static Future<void> save(JournalEntry e) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(await UserScope.prefix() + _kind + e.id, jsonEncode(e.toJson()));
  }

  /// Deletes the entry and its photos.
  static Future<void> delete(JournalEntry e) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(await UserScope.prefix() + _kind + e.id);
    for (final img in e.images) {
      await deleteImage(img);
    }
  }

  /// Diary notes used to live inside each day's tasks; move them into entries once.
  static Future<void> _migrateOldNotes(SharedPreferences prefs, String scope) async {
    if (prefs.getBool(scope + migratedKey) ?? false) return;
    final diary = '${scope}diary:';
    for (final k in prefs.getKeys().where((k) => k.startsWith(diary)).toList()) {
      final raw = prefs.getString(k);
      if (raw == null) continue;
      final day = DiaryDay.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (day.note.trim().isEmpty && day.mood == null) continue;
      final date = DateTime.parse(k.substring(diary.length));
      final entry = JournalEntry(
        id: 'm${date.millisecondsSinceEpoch}',
        date: DateTime(date.year, date.month, date.day, 21),
        text: day.note,
        mood: day.mood,
      );
      await prefs.setString(scope + _kind + entry.id, jsonEncode(entry.toJson()));
      day.note = '';
      day.mood = null;
      if (day.isEmpty) {
        await prefs.remove(k);
      } else {
        await prefs.setString(k, jsonEncode(day.toJson()));
      }
    }
    await prefs.setBool(scope + migratedKey, true);
  }
}
