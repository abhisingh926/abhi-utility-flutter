import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api_client.dart';

/// Privacy policy and terms of use, served by the backend (/privacy, /terms).
/// Google Play needs the privacy policy reachable from inside the app.
class LegalLinks {
  static const _channel = MethodChannel('abhi_utility/app');

  static String get privacyUrl => '${ApiClient.baseUrl}/privacy';
  static String get termsUrl => '${ApiClient.baseUrl}/terms';

  static Future<void> open(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _channel.invokeMethod<bool>('openUrl', {'url': url}).catchError((_) => false);
    if (ok != true) messenger.showSnackBar(SnackBar(content: Text('Open $url in your browser')));
  }

  /// "By creating an account you agree to the Terms and Privacy policy" with both links.
  static Widget agreement(BuildContext context, {required String action}) {
    final style = TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant);
    final link = style.copyWith(color: Theme.of(context).colorScheme.primary, decoration: TextDecoration.underline);
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('By $action you agree to the ', style: style),
        GestureDetector(onTap: () => open(context, termsUrl), child: Text('Terms of use', style: link)),
        Text(' and ', style: style),
        GestureDetector(onTap: () => open(context, privacyUrl), child: Text('Privacy policy', style: link)),
        Text('.', style: style),
      ],
    );
  }

  /// Two list tiles for settings / profile screens.
  static List<Widget> tiles(BuildContext context) => [
        ListTile(
          leading: const Icon(Icons.privacy_tip_outlined),
          title: const Text('Privacy policy'),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => open(context, privacyUrl),
        ),
        ListTile(
          leading: const Icon(Icons.gavel_outlined),
          title: const Text('Terms of use'),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => open(context, termsUrl),
        ),
      ];
}
