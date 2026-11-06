import 'package:flutter/material.dart';

/// Number pad for a 4–6 digit password.
///
/// [onSubmit] returns an error message to show (and clears the input), or null
/// when the password was accepted.
class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    required this.title,
    this.subtitle,
    required this.onSubmit,
    this.minLength = 4,
    this.maxLength = 6,
  });

  final String title;
  final String? subtitle;
  final Future<String?> Function(String pin) onSubmit;
  final int minLength;
  final int maxLength;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String _pin = '';
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    if (_pin.length < widget.minLength) {
      setState(() => _error = 'Use at least ${widget.minLength} digits');
      return;
    }
    setState(() => _busy = true);
    final error = await widget.onSubmit(_pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      if (error != null) _pin = '';
    });
  }

  void _press(String k) {
    if (_busy) return;
    setState(() {
      _error = null;
      if (k == '⌫') {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
      } else if (_pin.length < widget.maxLength) {
        _pin += k;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget key(String k) => Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: 72,
            height: 72,
            child: k == 'OK'
                ? FilledButton(
                    style: FilledButton.styleFrom(shape: const CircleBorder(), padding: EdgeInsets.zero),
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('OK', style: TextStyle(fontSize: 18)),
                  )
                : FilledButton.tonal(
                    style: FilledButton.styleFrom(shape: const CircleBorder(), padding: EdgeInsets.zero),
                    onPressed: () => _press(k),
                    child: k == '⌫'
                        ? const Icon(Icons.backspace_outlined)
                        : Text(k, style: const TextStyle(fontSize: 24)),
                  ),
          ),
        );

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 48, color: scheme.primary),
            const SizedBox(height: 12),
            Text(widget.title,
                textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
            if (widget.subtitle != null) ...[
              const SizedBox(height: 6),
              Text(widget.subtitle!,
                  textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < widget.maxLength; i++)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < _pin.length ? scheme.primary : null,
                      border: Border.all(
                        color: i < widget.minLength ? scheme.primary : scheme.outlineVariant,
                        width: 2,
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(
              height: 28,
              child: Center(
                child: Text(_error ?? '', style: TextStyle(color: scheme.error)),
              ),
            ),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
              ['⌫', '0', 'OK'],
            ])
              Row(mainAxisSize: MainAxisSize.min, children: [for (final k in row) key(k)]),
          ],
        ),
      ),
    );
  }
}

/// Create (or change) the password: enter it twice.
class PinSetup extends StatefulWidget {
  const PinSetup({super.key, required this.onDone, this.title = 'Create an App Lock password'});

  final Future<String?> Function(String pin) onDone;
  final String title;

  @override
  State<PinSetup> createState() => _PinSetupState();
}

class _PinSetupState extends State<PinSetup> {
  String? _first;
  bool _mismatch = false;

  @override
  Widget build(BuildContext context) {
    return _first == null
        ? PinPad(
            key: ValueKey('first$_mismatch'),
            title: widget.title,
            subtitle: _mismatch
                ? '❌ The two passwords did not match. Please start again.'
                : '4–6 digits. Needed to change locks or give extra time.\n'
                    'Keep it secret from kids 🙂',
            onSubmit: (pin) async {
              setState(() => _first = pin);
              return null;
            },
          )
        : PinPad(
            key: const ValueKey('confirm'),
            title: 'Enter it again',
            subtitle: 'To make sure there is no typo',
            onSubmit: (pin) async {
              if (pin != _first) {
                setState(() {
                  _first = null;
                  _mismatch = true;
                });
                return null;
              }
              return widget.onDone(pin);
            },
          );
  }
}
