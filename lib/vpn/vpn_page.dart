import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'vpn_server.dart';

class VpnPage extends StatefulWidget {
  const VpnPage({super.key});

  @override
  State<VpnPage> createState() => _VpnPageState();
}

class _VpnPageState extends State<VpnPage> with AutomaticKeepAliveClientMixin {
  /// How many servers to try before giving up (free servers are often down).
  static const int _maxAttempts = 5;
  static const Duration _attemptTimeout = Duration(seconds: 25);
  static const String _prefsKey = 'vpn_connected_server';

  late final OpenVPN _vpn;
  VPNStage _stage = VPNStage.disconnected;
  VpnStatus? _status;

  List<VpnServer> _servers = [];
  bool _loadingServers = false;
  String? _loadError;

  /// Selected country code, or null for Auto (best server anywhere).
  String? _selectedCountry;

  /// The server we are connected (or connecting) to.
  Map<String, dynamic>? _current;
  String _attemptInfo = '';
  bool _connecting = false;
  bool _cancelled = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _vpn = OpenVPN(
      onVpnStageChanged: (stage, raw) {
        if (mounted) setState(() => _stage = stage);
      },
      onVpnStatusChanged: (status) {
        if (mounted) setState(() => _status = status);
      },
    );
    _init();
  }

  Future<void> _init() async {
    await _vpn.initialize(
      localizedDescription: 'Abhi Utility VPN',
      lastStage: (stage) => setState(() => _stage = stage),
      lastStatus: (status) => setState(() => _status = status),
    );
    // If the VPN was already running when the app reopened, show its server.
    if (!_stage.isDisconnected) {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      if (saved != null && mounted) {
        setState(() => _current = jsonDecode(saved) as Map<String, dynamic>);
      }
    }
    await _loadServers();
  }

  Future<void> _loadServers() async {
    setState(() {
      _loadingServers = true;
      _loadError = null;
    });
    try {
      final servers = await fetchVpnGateServers();
      if (!mounted) return;
      setState(() => _servers = servers);
    } catch (e) {
      if (mounted) setState(() => _loadError = 'Could not load servers: $e');
    } finally {
      if (mounted) setState(() => _loadingServers = false);
    }
  }

  /// Countries with their servers, best country (by top score) first.
  Map<String, List<VpnServer>> get _byCountry {
    final map = <String, List<VpnServer>>{};
    for (final s in _servers) {
      map.putIfAbsent(s.countryCode, () => []).add(s);
    }
    return map;
  }

  List<VpnServer> get _candidates => _selectedCountry == null
      ? _servers
      : _servers.where((s) => s.countryCode == _selectedCountry).toList();

  Future<void> _connect() async {
    if (_servers.isEmpty) await _loadServers();
    if (_candidates.isEmpty) {
      _snack('No servers available for this country. Try Auto or refresh.');
      return;
    }

    setState(() {
      _connecting = true;
      _cancelled = false;
      _attemptInfo = 'Finding the fastest server…';
    });

    // Rank by latency from this phone, UDP and free bandwidth — not by the
    // VPN Gate score, which favours crowded servers.
    final candidates =
        (await rankServersForDevice(_candidates)).take(_maxAttempts).toList();
    if (_cancelled || !mounted) return;

    for (var i = 0; i < candidates.length && !_cancelled; i++) {
      final server = candidates[i];
      setState(() {
        _current = server.toJson();
        _attemptInfo = 'Trying ${server.flag} ${server.country} '
            '(${i + 1}/${candidates.length})';
      });

      try {
        final started = await _vpn.connect(
          server.config,
          '${server.country} · ${server.ip}',
        );
        if (!started) {
          // User refused the Android VPN permission.
          _snack('VPN permission is needed to connect.');
          break;
        }
      } on PlatformException catch (e) {
        _snack('Could not start VPN: ${e.message}');
        continue;
      }

      final result = await _vpn.stageStream
          .firstWhere((s) => s.isConnected || s.isDisconnected || _cancelled)
          .timeout(_attemptTimeout, onTimeout: () => _vpn.currentStage);

      if (_cancelled) break;
      if (result.isConnected) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsKey, jsonEncode(server.toJson()));
        setState(() {
          _connecting = false;
          _attemptInfo = '';
        });
        return;
      }
      // This server failed; stop it retrying and move on to the next one.
      await _vpn.disconnect();
    }

    if (mounted) {
      setState(() {
        _connecting = false;
        _attemptInfo = '';
        if (!_stage.isConnected) _current = null;
      });
      if (!_cancelled && !_stage.isConnected) {
        _snack('Could not connect. Servers may be busy — try another country.');
      }
    }
  }

  Future<void> _disconnect() async {
    _cancelled = true;
    await _vpn.disconnect();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    if (mounted) {
      setState(() {
        _connecting = false;
        _current = null;
        _attemptInfo = '';
      });
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _pickCountry() async {
    final byCountry = _byCountry;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scroll) => ListView(
          controller: scroll,
          children: [
            ListTile(
              leading: const Text('🌐', style: TextStyle(fontSize: 28)),
              title: const Text('Auto (best server)'),
              subtitle: const Text('Picks the best server in any country'),
              trailing: _selectedCountry == null ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, ''),
            ),
            const Divider(),
            for (final entry in byCountry.entries)
              ListTile(
                leading: Text(entry.value.first.flag, style: const TextStyle(fontSize: 28)),
                title: Text(entry.value.first.country),
                subtitle: Text(
                  '${entry.value.length} server${entry.value.length == 1 ? '' : 's'}'
                  ' · best ${entry.value.first.speedLabel}',
                ),
                trailing: _selectedCountry == entry.key ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, entry.key),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _selectedCountry = picked.isEmpty ? null : picked);
  }

  String _formatSpeed(int? bytesPerSec) {
    final b = bytesPerSec ?? 0;
    if (b > 1e6) return '${(b / 1e6).toStringAsFixed(1)} MB/s';
    if (b > 1e3) return '${(b / 1e3).toStringAsFixed(0)} KB/s';
    return '$b B/s';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final connected = _stage.isConnected;
    final busy = _connecting || _stage.isConnecting;
    final active = connected || busy;

    final selectedLabel = _selectedCountry == null
        ? '🌐  Auto (best server)'
        : () {
            final list = _byCountry[_selectedCountry];
            return list == null
                ? _selectedCountry!
                : '${list.first.flag}  ${list.first.country}';
          }();

    final statusText = connected
        ? 'Connected'
        : busy
            ? (_attemptInfo.isNotEmpty ? _attemptInfo : 'Connecting…')
            : 'Not connected';

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 16),
        Center(
          child: GestureDetector(
            onTap: active ? _disconnect : _connect,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: connected
                    ? Colors.green
                    : busy
                        ? Colors.orange
                        : scheme.surfaceContainerHighest,
                boxShadow: [
                  if (active)
                    BoxShadow(
                      color: (connected ? Colors.green : Colors.orange).withValues(alpha: 0.4),
                      blurRadius: 30,
                      spreadRadius: 4,
                    ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  busy
                      ? const SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 4),
                        )
                      : Icon(Icons.power_settings_new,
                          size: 64, color: connected ? Colors.white : scheme.onSurfaceVariant),
                  const SizedBox(height: 8),
                  Text(
                    connected ? 'DISCONNECT' : busy ? 'CANCEL' : 'CONNECT',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                      color: active ? Colors.white : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          statusText,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),

        // Connected server card.
        if (_current != null && active)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    countryFlag(_current!['countryCode'] as String),
                    style: const TextStyle(fontSize: 48),
                  ),
                  Text(
                    _current!['country'] as String,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text('Server ${_current!['ip']}',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                  if (connected) ...[
                    const Divider(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _stat('Time', _status?.duration ?? '00:00:00'),
                        _stat('↓ Down', _formatSpeed(_status?.speedIn)),
                        _stat('↑ Up', _formatSpeed(_status?.speedOut)),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),

        const SizedBox(height: 8),
        // Country selector.
        Card(
          child: ListTile(
            leading: const Icon(Icons.public),
            title: const Text('Server location'),
            subtitle: Text(selectedLabel),
            trailing: _loadingServers
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right),
            enabled: !active && _servers.isNotEmpty,
            onTap: _pickCountry,
          ),
        ),
        if (active)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Disconnect to change the location',
                textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        if (_loadError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_loadError!, style: TextStyle(color: scheme.error)),
          ),
        if (!active)
          TextButton.icon(
            onPressed: _loadingServers ? null : _loadServers,
            icon: const Icon(Icons.refresh),
            label: Text(_servers.isEmpty
                ? 'Load servers'
                : 'Refresh servers (${_byCountry.length} countries, ${_servers.length} servers)'),
          ),
        const SizedBox(height: 16),
        Text(
          'Free volunteer servers from VPN Gate (vpngate.net). Server operators can '
          'see your traffic — avoid using it for banking or private accounts.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _stat(String label, String value) => Column(
        children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      );

  @override
  void dispose() {
    _vpn.dispose(); // the VPN itself keeps running
    super.dispose();
  }
}
