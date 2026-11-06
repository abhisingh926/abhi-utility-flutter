import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A link the user looked up in the Downloader.
class HistoryLink {
  HistoryLink({required this.url, this.title, required this.time});

  HistoryLink.fromJson(Map<String, dynamic> j)
      : url = j['url'] as String,
        title = j['title'] as String?,
        time = DateTime.fromMillisecondsSinceEpoch(j['time'] as int);

  final String url;
  final String? title;
  final DateTime time;

  String get host => Uri.tryParse(url)?.host ?? url;

  Map<String, dynamic> toJson() => {'url': url, if (title != null) 'title': title, 'time': time.millisecondsSinceEpoch};
}

/// Downloader link history (newest first, max 50, no duplicates). Stored on the phone only.
class LinkHistory {
  static const _key = 'downloader_link_history';
  static const _max = 50;

  static Future<List<HistoryLink>> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // the quick panel may have added links in another engine
    return (prefs.getStringList(_key) ?? [])
        .map((s) => HistoryLink.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  static Future<void> _save(List<HistoryLink> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, list.take(_max).map((l) => jsonEncode(l.toJson())).toList());
  }

  /// Adds (or moves to the top) a link; keeps an existing title if none is given.
  static Future<void> add(String url, {String? title}) async {
    final list = await load();
    final old = list.where((l) => l.url == url).firstOrNull;
    list.removeWhere((l) => l.url == url);
    list.insert(0, HistoryLink(url: url, title: title ?? old?.title, time: DateTime.now()));
    await _save(list);
  }

  static Future<void> remove(String url) async {
    final list = await load()..removeWhere((l) => l.url == url);
    await _save(list);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
