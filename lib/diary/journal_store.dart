import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Diary entries in SharedPreferences (key `journal:<id>`); photos as files in the
/// app's private folder (kept even if deleted from the gallery).
class JournalStore {
  static const _prefix = 'journal:';
  static const _migratedKey = 'journal_migrated_v1';
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
    await _migrateOldNotes(prefs);
    final entries = [
      for (final k in prefs.getKeys().where((k) => k.startsWith(_prefix)))
        JournalEntry.fromJson(jsonDecode(prefs.getString(k)!) as Map<String, dynamic>),
    ]..sort((a, b) => b.date.compareTo(a.date));
    return entries;
  }

  static Future<void> save(JournalEntry e) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefix + e.id, jsonEncode(e.toJson()));
  }

  /// Deletes the entry and its photos.
  static Future<void> delete(JournalEntry e) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefix + e.id);
    for (final img in e.images) {
      await deleteImage(img);
    }
  }

  /// Diary notes used to live inside each day's tasks; move them into entries once.
  static Future<void> _migrateOldNotes(SharedPreferences prefs) async {
    if (prefs.getBool(_migratedKey) ?? false) return;
    for (final k in prefs.getKeys().where((k) => k.startsWith('diary:')).toList()) {
      final raw = prefs.getString(k);
      if (raw == null) continue;
      final day = DiaryDay.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (day.note.trim().isEmpty && day.mood == null) continue;
      final date = DateTime.parse(k.substring('diary:'.length));
      final entry = JournalEntry(
        id: 'm${date.millisecondsSinceEpoch}',
        date: DateTime(date.year, date.month, date.day, 21),
        text: day.note,
        mood: day.mood,
      );
      await prefs.setString(_prefix + entry.id, jsonEncode(entry.toJson()));
      day.note = '';
      day.mood = null;
      if (day.isEmpty) {
        await prefs.remove(k);
      } else {
        await prefs.setString(k, jsonEncode(day.toJson()));
      }
    }
    await prefs.setBool(_migratedKey, true);
  }
}
