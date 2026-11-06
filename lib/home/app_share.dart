import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shares this app's APK (native side: AppShare.kt).
class AppShare {
  static const _channel = MethodChannel('abhi_utility/app');

  static Future<({String version, int apkSize})> info() async {
    final m = await _channel.invokeMapMethod<String, Object>('info') ?? {};
    return (version: m['version'] as String? ?? '1.0', apkSize: (m['apkSize'] as int?) ?? 0);
  }

  /// Copies the APK to Downloads (takes a few seconds) and opens the share sheet.
  static Future<void> shareApk(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Expanded(child: Text('Preparing the app to share…')),
          ],
        ),
      ),
    );
    try {
      await _channel.invokeMethod('shareApk');
      navigator.pop();
    } on PlatformException catch (e) {
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('Could not share the app: ${e.message}')));
    }
  }
}
