// App Lock page (unlocked) renders without overflow at normal and large text, light and dark.
import 'package:abhi_utility/app_theme.dart';
import 'package:abhi_utility/applock/app_lock_page.dart';
import 'package:abhi_utility/diary/diary_lock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final scale in [1.0, 1.3]) {
    for (final dark in [false, true]) {
      testWidgets('App Lock page lays out (scale $scale, dark $dark)', (t) async {
        t.view.physicalSize = const Size(1080, 2340);
        t.view.devicePixelRatio = 2.625;
        addTearDown(t.view.reset);
        final m = t.binding.defaultBinaryMessenger;
        m.setMockMethodCallHandler(const MethodChannel('abhi_utility/reels'), (c) async => true);
        m.setMockMethodCallHandler(const MethodChannel('abhi_utility/applock'), (c) async => switch (c.method) {
              'hasPin' => true,
              'fingerprintEnabled' => true,
              'protectionStatus' => {'on': true, 'admin': false, 'guard': true},
              'rules' => [
                  {'pkg': 'com.instagram.android', 'label': 'Instagram', 'icon': null, 'mode': 'hourly', 'minutes': 5,
                   'usedSeconds': 60, 'limitSeconds': 300, 'locked': false, 'unlockAt': null},
                  {'pkg': 'com.google.android.youtube', 'label': 'YouTube with a very long name here', 'icon': null, 'mode': 'daily',
                   'minutes': 30, 'usedSeconds': 1800, 'limitSeconds': 1800, 'locked': true, 'unlockAt': 1794300000000},
                  {'pkg': 'x', 'label': 'Snapchat', 'icon': null, 'mode': 'block', 'minutes': 0,
                   'usedSeconds': 0, 'limitSeconds': 0, 'locked': true, 'unlockAt': null},
                ],
              _ => null,
            });
        DiaryLock.appLockUnlocked.value = true;
        await t.pumpWidget(MediaQuery(
          data: MediaQueryData(size: const Size(411, 891), textScaler: TextScaler.linear(scale)),
          child: MaterialApp(
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            home: const Scaffold(body: AppLockPage(active: true)),
          ),
        ));
        await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
        for (var i = 0; i < 10; i++) {
          await t.pump(const Duration(milliseconds: 200));
        }
        expect(find.text('Lock all social media'), findsOneWidget);
        await t.drag(find.byType(ListView), const Offset(0, -1500));
        for (var i = 0; i < 10; i++) {
          await t.pump(const Duration(milliseconds: 200));
        }
        expect(t.takeException(), isNull); // no overflow

      });
    }
  }
}
