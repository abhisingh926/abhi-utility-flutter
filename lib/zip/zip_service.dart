import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Talks to ZipTool.kt.
class ZipService {
  static const channel = MethodChannel('abhi_utility/zip');

  static String formatSize(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  static bool isWrongPassword(Object e) => e is PlatformException && e.code == 'WRONG_PASSWORD';

  static String message(Object e) => e is PlatformException ? (e.message ?? e.code) : '$e';

  /// Runs [work] behind a "please wait" dialog.
  static Future<T> withProgress<T>(BuildContext context, String text, Future<T> Function() work) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(child: Text(text)),
            ],
          ),
        ),
      ),
    );
    try {
      return await work();
    } finally {
      navigator.pop();
    }
  }

  /// Asks for a password. With [confirm] the user types it twice (new lock).
  static Future<String?> askPassword(
    BuildContext context, {
    required String title,
    String? message,
    bool confirm = false,
    String? error,
  }) {
    final a = TextEditingController();
    final b = TextEditingController();
    var hide = true;
    String? err = error;
    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          icon: const Icon(Icons.lock_outline),
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(message)),
              TextField(
                controller: a,
                autofocus: true,
                obscureText: hide,
                decoration: InputDecoration(
                  labelText: 'Password',
                  errorText: err,
                  suffixIcon: IconButton(
                    icon: Icon(hide ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => hide = !hide),
                  ),
                ),
              ),
              if (confirm)
                TextField(
                  controller: b,
                  obscureText: hide,
                  decoration: const InputDecoration(labelText: 'Type it again'),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (a.text.isEmpty) return setState(() => err = 'Enter a password');
                if (confirm && a.text.length < 4) return setState(() => err = 'At least 4 characters');
                if (confirm && a.text != b.text) return setState(() => err = "The passwords don't match");
                Navigator.pop(context, a.text);
              },
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
  }
}
