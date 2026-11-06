import 'package:shared_preferences/shared_preferences.dart';

/// Which features are pinned to the bottom bar (by tab index), in order.
class NavPrefs {
  static const _key = 'nav_pinned_tabs';

  /// Home + this many features fit the bar comfortably.
  static const maxPinned = 4;

  static Future<List<int>> load(List<int> defaults, Set<int> valid) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_key);
    if (saved == null) return defaults;
    return saved.map(int.tryParse).whereType<int>().where(valid.contains).take(maxPinned).toList();
  }

  static Future<void> save(List<int> tabs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, tabs.map((t) => '$t').toList());
  }
}
