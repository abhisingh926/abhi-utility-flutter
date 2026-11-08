import 'package:flutter/material.dart';

import 'api_client.dart';
import 'backup_service.dart';
import 'subscription_page.dart';
import 'subscription_service.dart';

/// Account: login / register when logged out, cloud backup when logged in.
/// Pops with `true` if a backup was restored (so the diary/tasks reload).
class AccountPage extends StatefulWidget {
  const AccountPage({super.key, this.register = false, this.closeOnLogin = false});

  /// Open on the "Register" tab (the free trial needs an account).
  final bool register;

  /// Go back as soon as the user is logged in (opened from a locked feature).
  final bool closeOnLogin;

  /// Bumped after a restore; the home shell listens and reloads Diary/Tasks.
  static final restoredVersion = ValueNotifier<int>(0);

  /// Opens the account / backup screen from anywhere in the app.
  static Future<void> open(BuildContext context, {bool register = false, bool closeOnLogin = false}) async {
    final restored = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AccountPage(register: register, closeOnLogin: closeOnLogin)),
    );
    if (restored == true) restoredVersion.value++;
  }

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _api = ApiClient.instance;
  bool _ready = false;
  bool _restored = false;

  @override
  void initState() {
    super.initState();
    _api.load().then((_) {
      if (mounted) setState(() => _ready = true);
    });
    if (widget.closeOnLogin) _api.user.addListener(_closeWhenLoggedIn);
  }

  bool _closed = false;

  void _closeWhenLoggedIn() {
    if (_closed || _api.user.value == null || !mounted) return;
    _closed = true; // the user can change again while the page animates out
    Navigator.pop(context, _restored);
  }

  @override
  void dispose() {
    _api.user.removeListener(_closeWhenLoggedIn);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _restored);
      },
      child: ValueListenableBuilder<AccountUser?>(
        valueListenable: _api.user,
        builder: (context, user, _) => Scaffold(
          appBar: AppBar(title: Text(user == null ? 'Account' : 'Backup & account')),
          body: !_ready
              ? const Center(child: CircularProgressIndicator())
              : user == null
                  ? _AuthForm(register: widget.register)
                  : _BackupView(user: user, onRestored: () => _restored = true),
        ),
      ),
    );
  }
}

// ---- Login / Register ------------------------------------------------------------------

class _AuthForm extends StatefulWidget {
  const _AuthForm({this.register = false});
  final bool register;

  @override
  State<_AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends State<_AuthForm> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _referral = TextEditingController();
  late bool _register = widget.register;
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  /// The server isn't reachable (not live yet): offer to use the app offline.
  bool _serverOffline = false;

  Future<void> _useOffline() async {
    final messenger = ScaffoldMessenger.of(context);
    await ApiClient.instance.startOffline();
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger.showSnackBar(const SnackBar(
      duration: Duration(seconds: 5),
      content: Text('Using the app offline. Everything is saved on this phone; register and sync when the server is live.'),
    ));
  }

  @override
  void dispose() {
    for (final c in [_name, _email, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _serverOffline = false;
    });
    try {
      final email = _email.text.trim();
      // The snack bar must outlive this page (it may close itself after login).
      final messenger = ScaffoldMessenger.of(context);
      final days = SubscriptionService.instance.trialDays;
      final bool trialStarted;
      if (_register) {
        trialStarted = await ApiClient.instance.register(
            email: email, password: _password.text, name: _name.text.trim(), referralCode: _referral.text);
        final ref = ApiClient.instance.lastReferral;
        if (ref != null && ref['applied'] != true) {
          // Account made, but the code couldn't be used (e.g. this email used one before).
          messenger.showSnackBar(SnackBar(content: Text('Referral code not used: ${ref['message'] ?? ''}')));
        }
      } else {
        trialStarted = await ApiClient.instance.login(email: email, password: _password.text);
      }
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 5),
        content: Text(trialStarted
            ? '🎁 Welcome! Your $days-day free trial has started: every feature is unlocked.'
            : _register
                ? 'Account created — welcome!'
                : 'Logged in'),
      ));
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _serverOffline = e.serverOffline;
          _error = e.serverOffline ? null : e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.cloud_sync_outlined, size: 64, color: scheme.primary),
                const SizedBox(height: 12),
                Text(_register ? 'Create an account' : 'Welcome back',
                    textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 6),
                Text(
                    _register
                        ? 'Register to get ${SubscriptionService.instance.trialLabel} free trial of every feature, '
                            'and back up your diary and tasks.'
                        : 'Back up your diary and tasks so you never lose them, even on a new phone.',
                    textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 24),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Login'), icon: Icon(Icons.login)),
                    ButtonSegment(value: true, label: Text('Register'), icon: Icon(Icons.person_add_alt)),
                  ],
                  selected: {_register},
                  onSelectionChanged: _busy
                      ? null
                      : (s) => setState(() {
                            _register = s.first;
                            _error = null;
                          }),
                ),
                const SizedBox(height: 20),
                if (_register) ...[
                  TextFormField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                        labelText: 'Name (optional)', prefixIcon: Icon(Icons.person_outline), border: OutlineInputBorder()),
                    validator: (v) => (v ?? '').trim().length > 100 ? 'At most 100 characters' : null,
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                      labelText: 'Email', prefixIcon: Icon(Icons.email_outlined), border: OutlineInputBorder()),
                  validator: (v) =>
                      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch((v ?? '').trim()) ? null : 'Enter a valid email',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  obscureText: !_showPassword,
                  autofillHints: [_register ? AutofillHints.newPassword : AutofillHints.password],
                  textInputAction: _register ? TextInputAction.next : TextInputAction.done,
                  onFieldSubmitted: _register ? null : (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _showPassword = !_showPassword),
                    ),
                  ),
                  validator: (v) {
                    if ((v ?? '').isEmpty) return 'Enter your password';
                    if (_register && (v!.length < 8 || v.length > 128)) return 'Use 8–128 characters';
                    return null;
                  },
                ),
                if (_register) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _confirm,
                    obscureText: !_showPassword,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                        labelText: 'Confirm password', prefixIcon: Icon(Icons.lock_outline), border: OutlineInputBorder()),
                    validator: (v) => v == _password.text ? null : 'Passwords do not match',
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _referral,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Referral code (optional)',
                      helperText: "Got a code from a friend? They'll get a free month",
                      prefixIcon: Icon(Icons.card_giftcard),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: scheme.error), textAlign: TextAlign.center),
                ],
                if (_serverOffline) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: scheme.surfaceContainerHighest,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.cloud_off_outlined),
                              SizedBox(width: 8),
                              Expanded(child: Text("The cloud server isn't live yet", style: TextStyle(fontWeight: FontWeight.bold))),
                            ],
                          ),
                          const SizedBox(height: 6),
                          const Text('You can use the app now; everything stays on this phone. '
                              'Register and sync once the server is live.'),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: _useOffline,
                            icon: const Icon(Icons.offline_bolt_outlined),
                            label: const Text('Use the app offline'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  child: _busy
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : Text(_register ? 'Create account' : 'Login'),
                ),
                if (!_register)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => _ForgotPasswordPage(email: _email.text.trim()))),
                    child: const Text('Forgot password?'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---- Forgot password -------------------------------------------------------------------

class _ForgotPasswordPage extends StatefulWidget {
  const _ForgotPasswordPage({required this.email});
  final String email;

  @override
  State<_ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<_ForgotPasswordPage> {
  late final _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _message;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() => _run(() async {
        final msg = await ApiClient.instance.forgotPassword(_email.text.trim());
        setState(() {
          _codeSent = true;
          _message = msg;
        });
      });

  Future<void> _reset() => _run(() async {
        if (_password.text.length < 8) throw ApiException(400, 'weak', 'New password must be 8–128 characters');
        await ApiClient.instance.resetPassword(
            email: _email.text.trim(), code: _code.text.trim(), newPassword: _password.text);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password changed — logged in')));
          Navigator.pop(context);
        }
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextField(
            controller: _email,
            enabled: !_codeSent,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
          ),
          if (_codeSent) ...[
            const SizedBox(height: 12),
            if (_message != null) Text(_message!),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(labelText: '6-digit code', border: OutlineInputBorder()),
            ),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password', border: OutlineInputBorder()),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : (_codeSent ? _reset : _send),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: Text(_codeSent ? 'Set new password' : 'Send code'),
          ),
        ],
      ),
    );
  }
}

// ---- Logged in: backups ----------------------------------------------------------------

class _BackupView extends StatefulWidget {
  const _BackupView({required this.user, required this.onRestored});
  final AccountUser user;
  final VoidCallback onRestored;

  @override
  State<_BackupView> createState() => _BackupViewState();
}

class _BackupViewState extends State<_BackupView> {
  List<BackupInfo>? _backups;
  int _used = 0, _quota = 0;
  String? _loadError;
  String? _status; // non-null while backing up / restoring

  /// Server not reachable (not live yet / no internet): data stays on the phone.
  bool _offline = false;

  /// A backup is waiting to be synced to the server.
  bool _pending = false;

  @override
  void initState() {
    super.initState();
    BackupService.syncIfPending().whenComplete(_refresh);
  }

  Future<void> _refresh() async {
    final pending = await BackupService.pendingSync();
    try {
      final r = await BackupService.list();
      if (!mounted) return;
      setState(() {
        _backups = r.backups;
        _used = r.usedBytes;
        _quota = r.quotaBytes;
        _loadError = null;
        _offline = false;
        _pending = pending;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _offline = e.serverOffline;
        _loadError = e.serverOffline ? null : e.message;
        _pending = pending;
      });
    }
  }

  /// Back up / sync; when the server is offline it's queued instead of failing.
  Future<void> _sync() async {
    var synced = false;
    await _work((p) async {
      synced = await BackupService.syncNow(progress: p);
    }, null);
    if (!mounted) return;
    _snack(synced
        ? '✅ Synced to the server'
        : 'Server not reachable. Your data is safe on this phone; it will sync when the server is live.');
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _work(Future<void> Function(void Function(String)) job, String? done) async {
    setState(() => _status = 'Starting…');
    try {
      await job((s) {
        if (mounted) setState(() => _status = s);
      });
      if (done != null) _snack(done);
      await _refresh();
    } on ApiException catch (e) {
      if (e.serverOffline) {
        if (mounted) setState(() => _offline = true);
        _snack('Server not reachable right now. Your data is safe on this phone; try Sync later.');
      } else {
        _snack(e.message);
      }
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _status = null);
    }
  }

  Future<void> _restore(BackupInfo b) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.restore, size: 40),
        title: const Text('Restore this backup?'),
        content: Text('Your diary and tasks on this phone will be replaced with the backup from '
            '${_fmt(b.createdAt)}. Back up first if you want to keep what is on the phone now.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restore')),
        ],
      ),
    );
    if (yes != true) return;
    await _work((p) async {
      await BackupService.restore(b.id, progress: p);
      widget.onRestored();
    }, '✅ Diary and tasks restored');
  }

  Future<void> _delete(BackupInfo b) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this backup?'),
        content: Text('Backup from ${_fmt(b.createdAt)} will be deleted from the server.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes == true) await _work((_) => BackupService.delete(b.id), 'Backup deleted');
  }

  Future<void> _logout() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('Your diary and tasks stay on this phone. Your backups stay on the server.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Log out')),
        ],
      ),
    );
    if (yes == true) await ApiClient.instance.logout();
  }

  static String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  static String _size(int b) => b < 1024 * 1024
      ? '${(b / 1024).toStringAsFixed(1)} KB'
      : '${(b / 1024 / 1024).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = _status != null;
    final u = widget.user;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: CircleAvatar(
                child: Text((u.name?.isNotEmpty == true ? u.name! : u.email)[0].toUpperCase()),
              ),
              title: Text(u.name?.isNotEmpty == true ? u.name! : u.email),
              subtitle: u.name?.isNotEmpty == true ? Text(u.email) : null,
              trailing: TextButton.icon(
                onPressed: busy ? null : _logout,
                icon: const Icon(Icons.logout),
                label: const Text('Log out'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const _PlanCard(),
          const SizedBox(height: 12),
          Card(
            color: scheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Cloud backup', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text('Saves all diary entries (with photos) and tasks to your account.'),
                  if (_quota > 0) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: (_used / _quota).clamp(0, 1)),
                    const SizedBox(height: 4),
                    Text('${_size(_used)} of ${_size(_quota)} used', style: Theme.of(context).textTheme.bodySmall),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: busy ? null : _sync,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    icon: busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.cloud_upload_outlined),
                    label: Text(_status ?? (_offline || _pending ? 'Sync now' : 'Back up now')),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Your backups', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_offline)
            Card(
              color: scheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.cloud_off_outlined, size: 32, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _pending
                            ? 'Server offline. A sync is waiting and will run automatically when the server is live.'
                            : 'Server offline. Your diary and tasks are safe on this phone. Tap "Sync now" when the server is live.',
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (_loadError != null)
            ListTile(
              leading: Icon(Icons.error_outline, color: scheme.error),
              title: Text(_loadError!),
              trailing: TextButton(onPressed: _refresh, child: const Text('Retry')),
            )
          else if (_backups == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (_backups!.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No backups yet. Tap "Back up now" to make your first one.', textAlign: TextAlign.center),
            )
          else
            for (final b in _backups!)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: Text(_fmt(b.createdAt)),
                  subtitle: Text([
                    if (b.entries != null) '${b.entries} diary entries',
                    if (b.taskDays != null) '${b.taskDays} task days',
                    '${b.photoCount} photos',
                    _size(b.sizeBytes),
                  ].join(' · ')),
                  trailing: PopupMenuButton<String>(
                    enabled: !busy,
                    onSelected: (a) => a == 'restore' ? _restore(b) : _delete(b),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'restore', child: ListTile(leading: Icon(Icons.restore), title: Text('Restore'))),
                      PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete'))),
                    ],
                  ),
                  onTap: busy ? null : () => _restore(b),
                ),
              ),
        ],
      ),
    );
  }
}

/// Trial / Pro status on the account page; opens the subscription screen.
class _PlanCard extends StatelessWidget {
  const _PlanCard();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Entitlement?>(
      valueListenable: ApiClient.instance.entitlement,
      builder: (context, ent, _) {
        final String text;
        if (ent == null) {
          text = 'Tap to check';
        } else if (ent.active && ent.isTrial) {
          text = 'Free trial · ${ent.daysLeft} days left';
        } else if (ent.active) {
          text = 'Pro${ent.expiresAt == null ? ' · lifetime' : ''}';
        } else {
          text = ent.trialUsed ? 'Trial ended · subscribe to continue' : 'No plan';
        }
        final ok = ent?.active ?? false;
        return Card(
          child: ListTile(
            leading: Icon(ok ? Icons.workspace_premium : Icons.lock_outline,
                color: ok ? Colors.amber.shade700 : Theme.of(context).colorScheme.error),
            title: const Text('Subscription'),
            subtitle: Text(text),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => SubscriptionPage.open(context),
          ),
        );
      },
    );
  }
}
