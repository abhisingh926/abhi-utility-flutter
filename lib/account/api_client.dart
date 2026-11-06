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

  @override
  String toString() => message;
}

/// Logged-in user (subset of the backend's publicUser).
class AccountUser {
  AccountUser({required this.id, required this.email, this.name});

  factory AccountUser.fromJson(Map<String, dynamic> j) =>
      AccountUser(id: j['id'] as int, email: j['email'] as String, name: j['name'] as String?);

  final int id;
  final String email;
  final String? name;

  Map<String, dynamic> toJson() => {'id': id, 'email': email, 'name': name};
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
    defaultValue: 'https://purple-koala-695199.hostingersite.com',
  );

  static const _kAccess = 'account:access';
  static const _kRefresh = 'account:refresh';
  static const _kUser = 'account:user';

  String? _access;
  String? _refresh;
  bool _loaded = false;

  /// The logged-in user, or null. Widgets listen to this.
  final user = ValueNotifier<AccountUser?>(null);

  bool get isLoggedIn => _refresh != null;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _access = prefs.getString(_kAccess);
    _refresh = prefs.getString(_kRefresh);
    final raw = prefs.getString(_kUser);
    if (_refresh != null && raw != null) {
      user.value = AccountUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
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
  }

  Future<void> _clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAccess);
    await prefs.remove(_kRefresh);
    await prefs.remove(_kUser);
    _access = null;
    _refresh = null;
    user.value = null;
  }

  // ---- Auth -------------------------------------------------------------------------

  Future<void> register({required String email, required String password, String? name}) async {
    final j = await _send('POST', '/api/v1/auth/register',
        body: {'email': email, 'password': password, if (name != null && name.isNotEmpty) 'name': name},
        auth: false);
    await _saveSession(j);
  }

  Future<void> login({required String email, required String password}) async {
    final j = await _send('POST', '/api/v1/auth/login', body: {'email': email, 'password': password}, auth: false);
    await _saveSession(j);
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
    var res = await call();
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
      throw ApiException(0, 'network', 'Could not reach the server. Check your internet connection.');
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
      return ApiException(res.statusCode, 'error', 'Server error (${res.statusCode})');
    }
  }
}
