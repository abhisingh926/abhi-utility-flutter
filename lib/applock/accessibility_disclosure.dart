import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Google Play "prominent disclosure": shown every time, before the user is sent
/// to Android's Accessibility settings. It must say what the service sees, what
/// it does with it, and get an explicit "Agree" (dismissing it = no).
/// Keep it in line with `reel_counter_description` in res/values/strings.xml
/// and with the Play Console accessibility declaration.
Future<void> openAccessibilityWithConsent(BuildContext context) async {
  final agreed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.settings_accessibility, size: 40),
      title: const Text('Accessibility service'),
      content: const SingleChildScrollView(
        child: Text(
          'Abhi Utility uses the Android Accessibility Service API for its parental-control '
          'and wellbeing features:\n\n'
          '• App Lock: sees which app is opened, to ask for the password before a locked app '
          'is shown and to enforce daily time limits.\n'
          '• Uninstall protection: reads the content of Android Settings and the uninstall screen '
          'only, to cover the screens that could remove or uninstall Abhi Utility with a password '
          'pad.\n'
          '• Reel counter: sees scrolling in Instagram, YouTube, Facebook, Snapchat and similar apps, '
          'and reads the YouTube Shorts progress bar, to count reels and time spent.\n'
          '• Download button: when you tap the ⬇ button in a web browser, reads the address bar once '
          'to get the page link to download.\n'
          '• SOS: notices when the lock screen is shown, so an emergency call can be started from it.\n\n'
          'What it does NOT do: it does not read your messages, passwords or what you type, and '
          'other apps are only seen by name. Nothing it sees is uploaded or shared — counts and '
          'settings stay on this phone.\n\n'
          'You can turn it off at any time in Settings → Accessibility (parents: turn off uninstall '
          'protection first, in App Lock).',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No thanks')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Agree')),
      ],
    ),
  );
  if (agreed == true) await const MethodChannel('abhi_utility/reels').invokeMethod('openSettings');
}
