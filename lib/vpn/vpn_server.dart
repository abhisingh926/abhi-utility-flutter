import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// One free public OpenVPN server from the VPN Gate project (vpngate.net).
class VpnServer {
  VpnServer({
    required this.hostName,
    required this.ip,
    required this.score,
    required this.ping,
    required this.speed,
    required this.country,
    required this.countryCode,
    required this.configBase64,
    this.sessions = 0,
  });

  final String hostName;
  final String ip;
  final int score;
  final int ping;

  /// Bits per second, as measured by VPN Gate.
  final int speed;
  final String country;
  final String countryCode;
  final String configBase64;

  /// Users currently connected, who all share [speed].
  final int sessions;

  /// Round-trip time measured from this device, or null if not probed /
  /// unreachable. Set by [rankServersForDevice].
  int? deviceRttMs;

  late final String config =
      utf8.decode(base64.decode(configBase64), allowMalformed: true);

  late final bool isUdp =
      RegExp(r'^\s*proto\s+udp', multiLine: true).hasMatch(config);

  /// Port from the `remote IP PORT` line.
  late final int port = int.tryParse(
          RegExp(r'^\s*remote\s+\S+\s+(\d+)', multiLine: true)
                  .firstMatch(config)
                  ?.group(1) ??
              '') ??
      443;

  /// Bandwidth each user can expect: total speed split across the users
  /// already on it. The VPN Gate "score" favours popular (crowded) servers.
  double get speedPerUser => speed / (sessions + 1);

  String get flag => countryFlag(countryCode);

  String get speedLabel => '${(speed / 1e6).toStringAsFixed(0)} Mbps';

  /// Short form saved to remember which server is connected.
  Map<String, Object> toJson() => {
        'hostName': hostName,
        'ip': ip,
        'country': country,
        'countryCode': countryCode,
      };
}

/// Turns a two-letter country code such as "JP" into its flag emoji.
String countryFlag(String code) {
  if (code.length != 2) return '🌐';
  final upper = code.toUpperCase();
  return String.fromCharCodes(upper.codeUnits.map((c) => 0x1F1E6 + c - 0x41));
}

/// Downloads the current server list from VPN Gate, best servers first.
Future<List<VpnServer>> fetchVpnGateServers() async {
  final res = await http
      .get(Uri.parse('https://www.vpngate.net/api/iphone/'))
      .timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) {
    throw Exception('VPN Gate returned HTTP ${res.statusCode}');
  }
  return parseVpnGateCsv(res.body);
}

/// The list is CSV: a "*vpn_servers" line, a "#HostName,..." header,
/// one line per server, and a closing "*".
List<VpnServer> parseVpnGateCsv(String body) {
  final servers = <VpnServer>[];
  for (final raw in const LineSplitter().convert(body)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('*') || line.startsWith('#')) continue;
    final f = line.split(',');
    if (f.length < 15) continue;
    // The config is always the last column; read it from the end in case
    // the operator message contains commas.
    final config = f.last;
    if (config.length < 100) continue;
    servers.add(VpnServer(
      hostName: f[0],
      ip: f[1],
      score: int.tryParse(f[2]) ?? 0,
      ping: int.tryParse(f[3]) ?? 0,
      speed: int.tryParse(f[4]) ?? 0,
      // e.g. "Croatia (LOCAL Name: Hrvatska)" -> "Croatia"
      country: f[5].replaceAll(RegExp(r'\s*\(.*\)'), '').trim(),
      countryCode: f[6].toUpperCase(),
      configBase64: config,
      sessions: int.tryParse(f[7]) ?? 0,
    ));
  }
  servers.sort((a, b) => b.score.compareTo(a.score));
  return servers;
}

/// Orders [pool] by what will actually be fast on this device:
///  1. reachable from here (TCP probe) – dead servers would only waste a
///     25 s connect attempt,
///  2. UDP before TCP – TCP-in-TCP collapses on lossy mobile links,
///  3. low latency from this device, then bandwidth per user.
/// All servers are probed in parallel (a list is ~100, ~2.5 s worst case).
Future<List<VpnServer>> rankServersForDevice(List<VpnServer> pool) async {
  await Future.wait(pool.map(_probe));

  int byBandwidth(VpnServer a, VpnServer b) =>
      b.speedPerUser.compareTo(a.speedPerUser);

  final reachable = pool.where((s) => s.deviceRttMs != null).toList()
    ..sort((a, b) {
      // Servers within the same ~75 ms band count as equally close; a big
      // latency gap matters more than UDP vs TCP.
      final band = (a.deviceRttMs! ~/ 75).compareTo(b.deviceRttMs! ~/ 75);
      if (band != 0) return band;
      if (a.isUdp != b.isUdp) return a.isUdp ? -1 : 1;
      return byBandwidth(a, b);
    });
  final failed = pool.where((s) => s.deviceRttMs == null);
  return [
    ...reachable,
    // UDP servers may simply have no TCP listener to probe; still worth a try.
    ...failed.where((s) => s.isUdp).toList()..sort(byBandwidth),
    ...failed.where((s) => !s.isUdp).toList()..sort(byBandwidth),
  ];
}

/// Times a TCP connect to the server. UDP OpenVPN ports can't be probed
/// this way, so for those try the SoftEther TCP listener on 443 instead
/// (VPN Gate servers normally run one); only the latency is used.
Future<void> _probe(VpnServer s) async {
  final port = s.isUdp ? 443 : s.port;
  final sw = Stopwatch()..start();
  try {
    final sock = await Socket.connect(s.ip, port,
        timeout: const Duration(milliseconds: 2500));
    s.deviceRttMs = sw.elapsedMilliseconds;
    sock.destroy();
  } catch (_) {
    s.deviceRttMs = null; // unreachable (or a UDP server with no TCP 443)
  }
}
