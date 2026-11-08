import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../account/user_scope.dart';

/// One to-do item.
class DiaryTask {
  DiaryTask({
    required this.id,
    required this.text,
    this.done = false,
    this.important = false,
    this.time,
  });

  DiaryTask.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        text = j['text'] as String,
        done = j['done'] as bool? ?? false,
        important = j['important'] as bool? ?? false,
        time = j['time'] as String?;

  final String id;
  String text;
  bool done;
  bool important;

  /// "HH:mm" (24h), optional.
  String? time;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'done': done,
        'important': important,
        if (time != null) 'time': time,
      };
}

/// Everything written for one day.
class DiaryDay {
  DiaryDay({List<DiaryTask>? tasks, this.note = '', this.mood})
      : tasks = tasks ?? [];

  DiaryDay.fromJson(Map<String, dynamic> j)
      : tasks = [for (final t in (j['tasks'] as List? ?? [])) DiaryTask.fromJson(t as Map<String, dynamic>)],
        note = j['note'] as String? ?? '',
        mood = j['mood'] as String?;

  final List<DiaryTask> tasks;
  String note;

  /// Emoji, optional.
  String? mood;

  bool get isEmpty => tasks.isEmpty && note.trim().isEmpty && mood == null;
  int get doneCount => tasks.where((t) => t.done).length;
  List<DiaryTask> get unfinished => tasks.where((t) => !t.done).toList();

  Map<String, dynamic> toJson() => {
        'tasks': [for (final t in tasks) t.toJson()],
        'note': note,
        if (mood != null) 'mood': mood,
      };
}

/// Summary of a day for the calendar.
enum DayMark { none, entry, allDone }

/// Diary storage: one JSON entry per day in SharedPreferences (`<account>:diary:yyyy-MM-dd`).
/// Each account on the phone has its own tasks (see [UserScope]).
class DiaryStore {
  static Future<String> _prefix() async => '${await UserScope.prefix()}diary:';

  static String key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static Future<DiaryDay> load(DateTime day) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(await _prefix() + key(day));
    if (raw == null) return DiaryDay();
    return DiaryDay.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  static Future<void> save(DateTime day, DiaryDay data) async {
    final prefs = await SharedPreferences.getInstance();
    final k = await _prefix() + key(day);
    if (data.isEmpty) {
      await prefs.remove(k);
    } else {
      await prefs.setString(k, jsonEncode(data.toJson()));
    }
  }

  /// Marks for every day of [month] that has something written.
  static Future<Map<int, DayMark>> monthMarks(DateTime month) async {
    final prefs = await SharedPreferences.getInstance();
    final prefix = '${await _prefix()}${key(DateTime(month.year, month.month, 1)).substring(0, 8)}';
    final marks = <int, DayMark>{};
    for (final k in prefs.getKeys().where((k) => k.startsWith(prefix))) {
      final day = int.tryParse(k.substring(prefix.length));
      final raw = prefs.getString(k);
      if (day == null || raw == null) continue;
      final d = DiaryDay.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (d.isEmpty) continue;
      marks[day] = d.tasks.isNotEmpty && d.doneCount == d.tasks.length ? DayMark.allDone : DayMark.entry;
    }
    return marks;
  }

  /// Unfinished tasks scheduled on days after [day], soonest first (then by time).
  static Future<List<({DateTime date, DiaryTask task})>> upcoming(DateTime day) async {
    final prefs = await SharedPreferences.getInstance();
    final p = await _prefix();
    final afterKey = p + key(day);
    final result = <({DateTime date, DiaryTask task})>[];
    for (final k in prefs.getKeys()) {
      if (!k.startsWith(p) || k.compareTo(afterKey) <= 0) continue;
      final date = DateTime.tryParse(k.substring(p.length));
      final raw = prefs.getString(k);
      if (date == null || raw == null) continue;
      final d = DiaryDay.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      for (final t in d.unfinished) {
        result.add((date: dateOnly(date), task: t));
      }
    }
    result.sort((a, b) {
      final byDate = a.date.compareTo(b.date);
      if (byDate != 0) return byDate;
      return (a.task.time ?? '99:99').compareTo(b.task.time ?? '99:99');
    });
    return result;
  }

  static String newId() => DateTime.now().microsecondsSinceEpoch.toString();
}
