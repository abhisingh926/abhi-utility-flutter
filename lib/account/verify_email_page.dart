import 'package:flutter/material.dart';

import 'api_client.dart';

/// "Confirm your email": the 6-digit code from the email starts the free trial
/// (and a referral code given at sign-up). Pops with true once confirmed.
class VerifyEmailPage extends StatefulWidget {
  const VerifyEmailPage({super.key, this.justRegistered = false, this.sendFailed = false});

  /// Opened right after sign-up (a code was already sent).
  final bool justRegistered;

  /// The sign-up email could not be sent: offer "Send code" straight away.
  final bool sendFailed;

  static Future<bool> open(BuildContext context, {bool justRegistered = false, bool sendFailed = false}) async =>
      await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => VerifyEmailPage(justRegistered: justRegistered, sendFailed: sendFailed))) ??
      false;

  @override
  State<VerifyEmailPage> createState() => _VerifyEmailPageState();
}

class _VerifyEmailPageState extends State<VerifyEmailPage> {
  final _api = ApiClient.instance;
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    final email = _api.user.value?.email ?? 'your email';
    _info = widget.justRegistered && !widget.sendFailed
        ? 'We sent a 6-digit code to $email.'
        : widget.sendFailed
            ? "We couldn't send the code to $email. Tap \"Send a new code\"."
            : 'Tap "Send a new code" and we will email a 6-digit code to $email.';
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await job();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() => _run(() async {
        final msg = await _api.sendVerificationCode();
        if (mounted) setState(() => _info = msg);
      });

  Future<void> _verify() => _run(() async {
        final code = _code.text.replaceAll(RegExp(r'\s'), '');
        if (!RegExp(r'^\d{6}$').hasMatch(code)) {
          throw ApiException(400, 'invalid', 'Enter the 6-digit code from the email.');
        }
        final r = await _api.verifyEmail(code);
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        final referral = r.referral;
        messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 6),
          content: Text([
            r.trialStarted ? '✅ Email confirmed — your free trial has started!' : '✅ Email confirmed.',
            if (referral != null && referral['applied'] == true && ((referral['friendDays'] as num?) ?? 0) > 0)
              '🎁 +${referral['friendDays']} bonus days from your referral code.',
            if (referral != null && referral['applied'] == false && referral['message'] != null)
              'Referral code not used: ${referral['message']}',
          ].join('\n')),
        ));
        Navigator.of(context).pop(true);
      });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm your email')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(Icons.mark_email_unread_outlined, size: 64, color: scheme.primary),
          const SizedBox(height: 12),
          Text(
            'Enter the code from the email to confirm your address and start your free trial.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (_info != null)
            Text(_info!, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 20),
          TextField(
            controller: _code,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 28, letterSpacing: 8),
            decoration: const InputDecoration(labelText: '6-digit code', border: OutlineInputBorder()),
            onSubmitted: (_) => _busy ? null : _verify(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _verify,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Confirm email'),
          ),
          TextButton(onPressed: _busy ? null : _resend, child: const Text('Send a new code')),
          const SizedBox(height: 8),
          Text(
            "Can't find it? Check the spam folder. The code expires after 30 minutes.",
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
