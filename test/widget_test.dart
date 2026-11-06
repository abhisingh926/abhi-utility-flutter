import 'package:abhi_utility/vpn/vpn_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses VPN Gate CSV and sorts by score', () {
    final cfg = 'A' * 120;
    final csv = '*vpn_servers\n'
        '#HostName,IP,Score,Ping,Speed,CountryLong,CountryShort,NumVpnSessions,Uptime,TotalUsers,TotalTraffic,LogType,Operator,Message,OpenVPN_ConfigData_Base64\n'
        'a,1.1.1.1,10,5,1000000,Japan,JP,1,1,1,1,2weeks,op,,$cfg\n'
        'b,2.2.2.2,99,5,1000000,Croatia (LOCAL Name: Hrvatska),HR,1,1,1,1,2weeks,op,hi, there,$cfg\n'
        '*\n';
    final servers = parseVpnGateCsv(csv);
    expect(servers.length, 2);
    expect(servers.first.countryCode, 'HR');
    expect(servers.first.country, 'Croatia');
    expect(servers.first.flag, '🇭🇷');
  });
}
