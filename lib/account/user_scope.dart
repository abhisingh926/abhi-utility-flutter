import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

/// Keeps personal data (diary entries, tasks) separate per account on this phone.
///
/// Keys are stored as `u<userId>:journal:<id>` / `u<userId>:diary:<date>`. Without
/// a login (offline mode) they go under `local:`.
///
/// Data that doesn't belong to an account yet is handed to the next account
/// that is logged in:
///  * `local:` data written in offline mode, before the user logged in;
///  * un-prefixed `journal:` / `diary:` keys from app versions before this one.
class UserScope {
  static const localPrefix = 'local:';
  static const _legacyMigrated = 'journal_migrated_v1';

  /// Data kinds stored per account (the part after the scope prefix).
  static const kinds = ['journal:', 'diary:'];

  static bool isDataKey(String unscoped) => kinds.any(unscoped.startsWith);

  /// The prefix for the current account, e.g. `u42:`; `local:` when logged out.
  static Future<String> prefix() async {
    final api = ApiClient.instance;
    await api.load();
    final user = api.user.value;
    if (user == null || !api.isLoggedIn) return localPrefix;
    final p = 'u${user.id}:';
    await _claimUnowned(p);
    return p;
  }

  /// Moves data with no owner (offline-mode or old-format keys) to account [p].
  static Future<void> _claimUnowned(String p) async {
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getKeys().where(isDataKey).toList();
    final local = prefs.getKeys().where((k) => k.startsWith(localPrefix) && isDataKey(k.substring(localPrefix.length))).toList();
    if (legacy.isEmpty && local.isEmpty) return;

    for (final k in legacy) {
      final v = prefs.getString(k);
      // Never overwrite something the account already has.
      if (v != null && !prefs.containsKey(p + k)) await prefs.setString(p + k, v);
      await prefs.remove(k);
    }
    for (final k in local) {
      final v = prefs.getString(k);
      final target = p + k.substring(localPrefix.length);
      if (v != null && !prefs.containsKey(target)) await prefs.setString(target, v);
      await prefs.remove(k);
    }
    // Old installs already moved diary notes into journal entries.
    if (legacy.isNotEmpty && (prefs.getBool(_legacyMigrated) ?? false)) {
      await prefs.setBool(p + _legacyMigrated, true);
    }
  }
}
