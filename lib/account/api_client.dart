import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Error from the backend: `{ error: { code, message } }`.
class ApiException implements Exception {
  ApiException(this.status, this.code, this.message, [this.body]);
  final int status;
  final String code;
  final String message;
  final Map<String, dynamic>? body;

  /// The backend can't be reached (no internet, or not deployed yet): not a
  /// real error. The app keeps working on this phone and syncs later.
  bool get serverOffline => code == 'server_offline';

  @override
  String toString() => message;
}

const _offlineMessage = 'The cloud server is not available right now. '
    'Your data is safe on this phone; you can sync it when the server is live.';

/// Logged-in user (subset of the backend's publicUser).
class AccountUser {
  AccountUser({required this.id, required this.email, this.name, this.accountToken});

  factory AccountUser.fromJson(Map<String, dynamic> j) => AccountUser(
      id: j['id'] as int,
      email: j['email'] as String,
      name: j['name'] as String?,
      accountToken: j['accountToken'] as String?);

  final int id;
  final String email;
  final String? name;

  /// Sent to Google Play / Apple with a purchase, so renewals reach this account.
  final String? accountToken;

  Map<String, dynamic> toJson() => {'id': id, 'email': email, 'name': name, 'accountToken': accountToken};
}

/// Whether the user may use the app: free trial or paid Pro (backend `entitlement`).
class Entitlement {
  Entitlement({
    required this.isPro,
    required this.isTrial,
    this.source,
    this.productId,
    this.expiresAt,
    this.autoRenew = false,
    this.trialUsed = false,
    this.trialEndsAt,
  });

  factory Entitlement.fromJson(Map<String, dynamic> j) {
    DateTime? date(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
    final trial = j['trial'] is Map ? j['trial'] as Map<String, dynamic> : const <String, dynamic>{};
    return Entitlement(
      isPro: j['isPro'] == true,
      isTrial: j['isTrial'] == true || j['source'] == 'trial',
      source: j['source'] as String?,
      productId: j['productId'] as String?,
      expiresAt: date(j['expiresAt']),
      autoRenew: j['autoRenew'] == true,
      trialUsed: trial['used'] == true,
      trialEndsAt: date(trial['endsAt']),
    );
  }

  final bool isPro;
  final bool isTrial;
  final String? source; // google | apple | admin | trial
  final String? productId;
  final DateTime? expiresAt; // null = lifetime
  final bool autoRenew;
  final bool trialUsed;
  final DateTime? trialEndsAt;

  /// True while the trial or subscription lasts (also checked offline from the saved copy).
  bool get active => isPro && (expiresAt == null || expiresAt!.isAfter(DateTime.now()));

  /// Whole days left (rounded up), or null for lifetime.
  int? get daysLeft {
    if (expiresAt == null) return null;
    final left = expiresAt!.difference(DateTime.now());
    return left.isNegative ? 0 : (left.inHours / 24).ceil();
  }

  Map<String, dynamic> toJson() => {
        'isPro': isPro,
        'isTrial': isTrial,
        'source': source,
        'productId': productId,
        'expiresAt': expiresAt?.toUtc().toIso8601String(),
        'autoRenew': autoRenew,
        'trial': {'used': trialUsed, 'endsAt': trialEndsAt?.toUtc().toIso8601String()},
      };
}

/// Talks to the Abhi Utility backend and keeps the login tokens.
///
/// Server address: build with `--dart-define=API_URL=https://your-site` to change it
/// (Android emulator + local server: `--dart-define=API_URL=http://10.0.2.2:3000`).
class ApiClient {
  ApiClient._();
  static final instance = ApiClient._();

  static const baseUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'https://palegreen-whale-996077.hostingersite.com',
  );

  static const _kAccess = 'account:access';
  static const _kRefresh = 'account:refresh';
  static const _kUser = 'account:user';
  static const _kEntitlement = 'account:entitlement';
  static const _kOffline = 'account:offline';
  static const _kOfflineSince = 'account:offlineSince';

  /// How long the app may be used without the server (before it is live).
  static const offlineDays = 30;

  String? _access;
  String? _refresh;
  bool _loaded = false;

  /// The logged-in user, or null. Widgets listen to this.
  final user = ValueNotifier<AccountUser?>(null);

  /// Free trial / Pro status of the logged-in user (null = logged out or not known yet).
  final entitlement = ValueNotifier<Entitlement?>(null);

  /// "Use the app offline" was chosen because the server wasn't reachable.
  final offlineMode = ValueNotifier<bool>(false);
  DateTime? _offlineSince;

  /// Offline use is allowed for [offlineDays] from the first time it was chosen.
  bool get offlineAccess =>
      offlineMode.value &&
      _offlineSince != null &&
      DateTime.now().difference(_offlineSince!).inDays < offlineDays;

  int get offlineDaysLeft => _offlineSince == null
      ? offlineDays
      : (offlineDays - DateTime.now().difference(_offlineSince!).inDays).clamp(0, offlineDays);

  /// May the features be used right now?
  bool get hasAccess => (isLoggedIn && (entitlement.value?.active ?? false)) || offlineAccess;

  /// Use the app without the server (it isn't live yet). Sync later.
  Future<void> startOffline() async {
    final prefs = await SharedPreferences.getInstance();
    _offlineSince ??= DateTime.now(); // the 30 days count from the very first time
    await prefs.setString(_kOfflineSince, _offlineSince!.toIso8601String());
    await prefs.setBool(_kOffline, true);
    offlineMode.value = true;
  }

  Future<void> _endOffline() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOffline, false); // offlineSince is kept: no second 30 days
    offlineMode.value = false;
  }

  /// True when the backend answers its health check.
  Future<bool> serverReachable() async {
    try {
      final res = await http.get(Uri.parse('$baseUrl/api/health')).timeout(const Duration(seconds: 10));
      return res.statusCode == 200 && (jsonDecode(res.body) as Map)['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  bool get isLoggedIn => _refresh != null;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _access = prefs.getString(_kAccess);
    _refresh = prefs.getString(_kRefresh);
    _offlineSince = DateTime.tryParse(prefs.getString(_kOfflineSince) ?? '');
    offlineMode.value = prefs.getBool(_kOffline) ?? false;
    final raw = prefs.getString(_kUser);
    if (_refresh != null && raw != null) {
      user.value = AccountUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      final ent = prefs.getString(_kEntitlement);
      if (ent != null) {
        try {
          entitlement.value = Entitlement.fromJson(jsonDecode(ent) as Map<String, dynamic>);
        } catch (_) {/* old format: fetched again by refreshAccount */}
      }
    }
    _loaded = true;
  }

  Future<void> _saveSession(Map<String, dynamic> j) async {
    final prefs = await SharedPreferences.getInstance();
    _access = j['accessToken'] as String?;
    if (j['refreshToken'] != null) _refresh = j['refreshToken'] as String;
    await prefs.setString(_kAccess, _access ?? '');
    await prefs.setString(_kRefresh, _refresh!);
    if (j['user'] is Map) {
      final u = AccountUser.fromJson(j['user'] as Map<String, dynamic>);
      await prefs.setString(_kUser, jsonEncode(u.toJson()));
      user.value = u;
    }
    if (j['entitlement'] is Map) await setEntitlement(j['entitlement'] as Map<String, dynamic>);
    if (offlineMode.value) await _endOffline(); // the server works: back to normal
  }

  /// Saves the entitlement from any backend answer (`/me`, login, purchases).
  Future<void> setEntitlement(Map<String, dynamic> j) async {
    final e = Entitlement.fromJson(j);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEntitlement, jsonEncode(e.toJson()));
    entitlement.value = e;
  }

  /// Reloads the user and their trial / subscription status from the server.
  /// Offline: keeps the saved status.
  Future<void> refreshAccount() async {
    await load();
    if (!isLoggedIn) return;
    final j = await json('GET', '/api/v1/me');
    if (j['user'] is Map) {
      final prefs = await SharedPreferences.getInstance();
      final u = AccountUser.fromJson(j['user'] as Map<String, dynamic>);
      await prefs.setString(_kUser, jsonEncode(u.toJson()));
      user.value = u;
    }
    if (j['entitlement'] is Map) await setEntitlement(j['entitlement'] as Map<String, dynamic>);
  }

  Future<void> _clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAccess);
    await prefs.remove(_kRefresh);
    await prefs.remove(_kUser);
    await prefs.remove(_kEntitlement);
    _access = null;
    _refresh = null;
    user.value = null;
    entitlement.value = null;
  }

  // ---- Auth -------------------------------------------------------------------------

  /// Creates the account; returns true when the free trial started.
  Future<bool> register({required String email, required String password, String? name}) async {
    final j = await _send('POST', '/api/v1/auth/register',
        body: {'email': email, 'password': password, if (name != null && name.isNotEmpty) 'name': name},
        auth: false);
    await _saveSession(j);
    return j['trialStarted'] == true;
  }

  /// Logs in; returns true when the free trial started (older accounts).
  Future<bool> login({required String email, required String password}) async {
    final j = await _send('POST', '/api/v1/auth/login', body: {'email': email, 'password': password}, auth: false);
    await _saveSession(j);
    return j['trialStarted'] == true;
  }

  /// Emails a 6-digit reset code.
  Future<String> forgotPassword(String email) async {
    final j = await _send('POST', '/api/v1/auth/forgot-password', body: {'email': email}, auth: false);
    return j['message'] as String? ?? 'Code sent';
  }

  Future<void> resetPassword({required String email, required String code, required String newPassword}) async {
    final j = await _send('POST', '/api/v1/auth/reset-password',
        body: {'email': email, 'code': code, 'newPassword': newPassword}, auth: false);
    await _saveSession(j);
  }

  Future<void> logout() async {
    final token = _refresh;
    await _clearSession();
    if (token != null) {
      try {
        await _send('POST', '/api/v1/auth/logout', body: {'refreshToken': token}, auth: false);
      } catch (_) {/* offline: the token just expires */}
    }
  }

  Future<bool> _refreshTokens() async {
    if (_refresh == null) return false;
    try {
      final j = await _send('POST', '/api/v1/auth/refresh', body: {'refreshToken': _refresh}, auth: false);
      await _saveSession(j);
      return true;
    } on ApiException catch (e) {
      // Refresh token revoked/expired or account disabled -> logged out.
      if (e.status == 401 || e.status == 403) await _clearSession();
      return false;
    }
  }

  // ---- Requests ---------------------------------------------------------------------

  /// JSON request. With [auth], sends the access token and refreshes it once on 401.
  Future<Map<String, dynamic>> json(String method, String path, {Object? body}) =>
      _send(method, path, body: body, auth: true);

  /// GET that needs no login (e.g. `/api/v1/plans`).
  Future<Map<String, dynamic>> publicJson(String path) => _send('GET', path, auth: false);

  /// Raw bytes upload (backup photos).
  Future<Map<String, dynamic>> putBytes(String path, Uint8List bytes) =>
      _send('PUT', path, bytes: bytes, auth: true);

  /// Raw bytes download (backup photos).
  Future<Uint8List> getBytes(String path) async {
    final res = await _authed(() => http.get(Uri.parse('$baseUrl$path'), headers: _headers(true)));
    if (res.statusCode >= 400) throw _error(res);
    return res.bodyBytes;
  }

  Map<String, String> _headers(bool auth, {bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        if (auth && _access != null) 'Authorization': 'Bearer $_access',
      };

  Future<http.Response> _authed(Future<http.Response> Function() call) async {
    await load();
    if (_refresh == null) throw ApiException(401, 'not_logged_in', 'Please log in first');
    http.Response res;
    try {
      res = await call();
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException(0, 'server_offline', _offlineMessage); // no connection
    }
    if (res.statusCode == 401 && await _refreshTokens()) res = await call();
    if (res.statusCode == 401) await _clearSession();
    return res;
  }

  Future<Map<String, dynamic>> _send(String method, String path,
      {Object? body, Uint8List? bytes, required bool auth}) async {
    final uri = Uri.parse('$baseUrl$path');
    Future<http.Response> call() async {
      final req = http.Request(method, uri)
        ..headers.addAll(_headers(auth, json: bytes == null));
      if (bytes != null) {
        req.headers['Content-Type'] = 'application/octet-stream';
        req.bodyBytes = bytes;
      } else if (body != null) {
        req.body = jsonEncode(body);
      }
      return http.Response.fromStream(await req.send().timeout(const Duration(seconds: 60)));
    }

    final http.Response res;
    try {
      res = auth ? await _authed(call) : await call();
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(0, 'server_offline', _offlineMessage);
    }
    if (res.statusCode >= 400) throw _error(res);
    if (res.body.isEmpty) return {};
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  ApiException _error(http.Response res) {
    try {
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final err = j['error'] as Map<String, dynamic>;
      return ApiException(res.statusCode, err['code'] as String? ?? 'error',
          err['message'] as String? ?? 'Something went wrong', {...err, ...j});
    } catch (_) {
      // Not our JSON (e.g. the host's 404 page): the backend isn't live there yet.
      return ApiException(res.statusCode, 'server_offline', _offlineMessage);
    }
  }
}
