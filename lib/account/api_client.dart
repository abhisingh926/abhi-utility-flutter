import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
  AccountUser({required this.id, required this.email, this.name, this.accountToken, this.avatarVersion});

  factory AccountUser.fromJson(Map<String, dynamic> j) => AccountUser(
      id: j['id'] as int,
      email: j['email'] as String,
      name: j['name'] as String?,
      accountToken: j['accountToken'] as String?,
      avatarVersion: j['avatarVersion'] as String?);

  final int id;
  final String email;
  final String? name;

  /// Changes whenever the profile photo changes; null = no photo.
  final String? avatarVersion;

  /// Sent to Google Play / Apple with a purchase, so renewals reach this account.
  final String? accountToken;

  Map<String, dynamic> toJson() =>
      {'id': id, 'email': email, 'name': name, 'accountToken': accountToken, 'avatarVersion': avatarVersion};
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
  static const _kEntitlementChecked = 'account:entitlementCheckedAt';
  static const _kLastSeen = 'account:lastSeen';

  /// The saved Pro status is trusted this long without reaching the server
  /// (a refund or cancellation shows up at the next check).
  static const entitlementGraceDays = 14;

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

  /// When the app was first installed (Android keeps this through "Clear data").
  DateTime? _installedAt;

  /// Latest time this app has seen: the clock going back means someone turned
  /// it back to stretch the trial / offline days.
  DateTime? _lastSeen;
  DateTime? _entitlementCheckedAt;

  bool get _clockTurnedBack =>
      _lastSeen != null && DateTime.now().isBefore(_lastSeen!.subtract(const Duration(hours: 1)));

  /// Offline days count from the first install (or the first offline use, if
  /// earlier), so clearing the app's data doesn't give 30 new days.
  DateTime? get _offlineStart {
    final a = _installedAt, b = _offlineSince;
    if (a == null) return b;
    if (b == null) return a;
    return a.isBefore(b) ? a : b;
  }

  /// Offline use is allowed for [offlineDays] after [_offlineStart].
  bool get offlineAccess =>
      offlineMode.value &&
      _offlineStart != null &&
      !_clockTurnedBack &&
      DateTime.now().difference(_offlineStart!).inDays < offlineDays;

  int get offlineDaysLeft => _offlineStart == null
      ? offlineDays
      : (offlineDays - DateTime.now().difference(_offlineStart!).inDays).clamp(0, offlineDays);

  /// The saved status was confirmed by the server recently enough.
  bool get _entitlementFresh =>
      _entitlementCheckedAt != null &&
      DateTime.now().difference(_entitlementCheckedAt!).inDays < entitlementGraceDays;

  /// May the features be used right now?
  bool get hasAccess =>
      (isLoggedIn && (entitlement.value?.active ?? false) && _entitlementFresh && !_clockTurnedBack) ||
      offlineAccess;

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
    try {
      final ms = await const MethodChannel('abhi_utility/app').invokeMethod<int>('firstInstallTime');
      if (ms != null) _installedAt = DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {/* not on Android (tests): use offlineSince */}
    _lastSeen = DateTime.tryParse(prefs.getString(_kLastSeen) ?? '');
    final now = DateTime.now();
    if (_lastSeen == null || now.isAfter(_lastSeen!)) {
      _lastSeen = now;
      await prefs.setString(_kLastSeen, now.toIso8601String());
    }
    _entitlementCheckedAt = DateTime.tryParse(prefs.getString(_kEntitlementChecked) ?? '');
    if (_entitlementCheckedAt == null && prefs.containsKey(_kEntitlement)) {
      // Saved before this check existed: give it one grace period.
      _entitlementCheckedAt = now;
      await prefs.setString(_kEntitlementChecked, now.toIso8601String());
    }
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
    // Fresh from the server: a correct clock and a confirmed status.
    final now = DateTime.now();
    _entitlementCheckedAt = now;
    await prefs.setString(_kEntitlementChecked, now.toIso8601String());
    if (_lastSeen == null || now.isAfter(_lastSeen!)) {
      _lastSeen = now;
      await prefs.setString(_kLastSeen, now.toIso8601String());
    }
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
    await prefs.remove(_kEntitlementChecked);
    _entitlementCheckedAt = null;
    _access = null;
    _refresh = null;
    user.value = null;
    entitlement.value = null;
  }

  // ---- Auth -------------------------------------------------------------------------

  /// What happened to the referral code given at the last [register] (null = none given).
  Map<String, dynamic>? lastReferral;

  /// Creates the account; returns true when the free trial started.
  Future<bool> register({required String email, required String password, String? name, String? referralCode}) async {
    final j = await _send('POST', '/api/v1/auth/register',
        body: {
          'email': email,
          'password': password,
          if (name != null && name.isNotEmpty) 'name': name,
          if (referralCode != null && referralCode.trim().isNotEmpty) 'referralCode': referralCode.trim(),
        },
        auth: false);
    await _saveSession(j);
    lastReferral = j['referral'] is Map ? j['referral'] as Map<String, dynamic> : null;
    return j['trialStarted'] == true;
  }

  /// Changes the password (other devices are logged out; this one stays logged in).
  Future<void> changePassword({required String current, required String newPassword}) async {
    final j = await json('POST', '/api/v1/auth/change-password',
        body: {'currentPassword': current, 'newPassword': newPassword});
    await _saveSession(j);
  }

  /// Updates the display name.
  Future<void> updateName(String name) async {
    await json('PATCH', '/api/v1/me', body: {'name': name.trim()});
    await refreshAccount();
  }

  /// Uploads a new profile photo (a JPEG made by squareAvatarJpeg); returns the new version.
  Future<String?> uploadAvatar(Uint8List jpeg) async {
    final j = await putBytes('/api/v1/me/avatar', jpeg);
    return (await _saveUser(j))?.avatarVersion;
  }

  /// Removes the profile photo.
  Future<void> removeAvatar() async => _saveUser(await json('DELETE', '/api/v1/me/avatar'));

  Future<AccountUser?> _saveUser(Map<String, dynamic> j) async {
    if (j['user'] is! Map) return null;
    final u = AccountUser.fromJson(j['user'] as Map<String, dynamic>);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUser, jsonEncode(u.toJson()));
    user.value = u;
    return u;
  }

  /// Deletes the account and its backups on the server, then logs out here.
  Future<void> deleteAccount(String password) async {
    await json('DELETE', '/api/v1/me', body: {'password': password});
    await _clearSession();
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

  /// The refresh in progress: requests that hit 401 at the same time wait for
  /// it instead of sending the (rotated, now invalid) refresh token again.
  Future<_Refresh>? _refreshing;

  Future<_Refresh> _refreshTokens() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<_Refresh> _doRefresh() async {
    final token = _refresh;
    if (token == null) return _Refresh.rejected;
    try {
      final j = await _send('POST', '/api/v1/auth/refresh', body: {'refreshToken': token}, auth: false);
      await _saveSession(j);
      return _Refresh.ok;
    } on ApiException catch (e) {
      // Refresh token revoked/expired or account disabled -> logged out.
      if (e.status == 401 || e.status == 403) {
        if (_refresh == token) await _clearSession(); // not if a newer login happened meanwhile
        return _Refresh.rejected;
      }
      return _Refresh.failed; // no connection / server error: stay logged in
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
    final sentWith = _access; // the token this request is sent with
    http.Response res;
    try {
      res = await call();
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException(0, 'server_offline', _offlineMessage); // no connection
    }
    if (res.statusCode == 401) {
      // Another request may already have refreshed while this one was on its way.
      final r = _refreshing != null || sentWith == _access ? await _refreshTokens() : _Refresh.ok;
      switch (r) {
        case _Refresh.ok:
          try {
            res = await call();
          } catch (_) {
            throw ApiException(0, 'server_offline', _offlineMessage);
          }
          if (res.statusCode == 401) await _clearSession(); // even a fresh token is refused
        case _Refresh.failed:
          // Couldn't renew the session right now (network / server): keep it.
          throw ApiException(0, 'server_offline', _offlineMessage);
        case _Refresh.rejected:
          break; // logged out by _doRefresh
      }
    }
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

enum _Refresh { ok, failed, rejected }
