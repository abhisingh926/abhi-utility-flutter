import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class FlashlightPage extends StatefulWidget {
  const FlashlightPage({super.key});

  @override
  State<FlashlightPage> createState() => _FlashlightPageState();
}

class _FlashlightPageState extends State<FlashlightPage> {
  // Native side lives in android/app/src/main/kotlin/.../MainActivity.kt
  // and ShakeService.kt, which does the shake detection in the background.
  static const _control = MethodChannel('abhi_utility/control');
  static const _torchEvents = EventChannel('abhi_utility/torch');

  StreamSubscription<dynamic>? _torchSub;
  bool _torchOn = false;
  bool _torchAvailable = true;
  bool _shakeEnabled = false;

  @override
  void initState() {
    super.initState();
    _torchSub = _torchEvents.receiveBroadcastStream().listen(
      (on) => setState(() => _torchOn = on as bool),
      onError: (_) {},
    );
    _init();
  }

  Future<void> _init() async {
    try {
      final hasTorch = await _control.invokeMethod<bool>('hasTorch') ?? false;
      setState(() => _torchAvailable = hasTorch);
      // Shake detection runs in the background service, so start it on launch.
      if (hasTorch) await _setShake(true);
    } on PlatformException catch (e) {
      _showError(e.message);
    }
  }

  Future<void> _setShake(bool enable) async {
    try {
      await _control.invokeMethod(enable ? 'startService' : 'stopService');
      setState(() => _shakeEnabled = enable);
    } on PlatformException catch (e) {
      _showError(e.message);
    }
  }

  Future<void> _toggleTorch() async {
    if (!_torchAvailable) return;
    try {
      await _control.invokeMethod('toggleTorch');
    } on PlatformException catch (e) {
      _showError(e.message);
    }
  }

  void _showError(String? msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Flashlight error: ${msg ?? 'unknown'}')),
    );
  }

  @override
  void dispose() {
    _torchSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = _torchOn ? Colors.black87 : Colors.white;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      color: _torchOn ? Colors.amber.shade100 : Colors.grey.shade900,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: _toggleTorch,
                child: Icon(
                  _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                  size: 160,
                  color: _torchOn ? Colors.amber.shade700 : Colors.grey,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                !_torchAvailable
                    ? 'No flashlight on this device'
                    : _torchOn
                        ? 'Flashlight ON'
                        : 'Flashlight OFF',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: fg),
              ),
              const SizedBox(height: 8),
              Text('Tap the icon to toggle', style: TextStyle(color: fg.withValues(alpha: 0.7))),
              const SizedBox(height: 32),
              SwitchListTile(
                value: _shakeEnabled,
                onChanged: _torchAvailable ? _setShake : null,
                title: Text('Shake to toggle', style: TextStyle(color: fg)),
                subtitle: Text(
                  'Keeps working when the app is closed',
                  style: TextStyle(color: fg.withValues(alpha: 0.7)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
