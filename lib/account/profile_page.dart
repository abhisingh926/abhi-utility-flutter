import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'account_page.dart';
import 'api_client.dart';
import 'subscription_page.dart';

/// Profile: your details, your subscription (and its history), the referral
/// program, and account actions (change password, log out, delete).
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  /// Logged in: the profile. Logged out: the login / register screen.
  static Future<void> open(BuildContext context) async {
    await ApiClient.instance.load();
    if (!context.mounted) return;
    if (!ApiClient.instance.isLoggedIn) return AccountPage.open(context);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfilePage()));
  }

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  static const _app = MethodChannel('abhi_utility/app');
  final _api = ApiClient.instance;

  Map<String, dynamic>? _me; // /me user (createdAt, lastLoginAt…)
  List<Map<String, dynamic>>? _subs;
  Map<String, dynamic>? _referral;
  bool _offline = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final results = await Future.wait([
        _api.json('GET', '/api/v1/me'),
        _api.json('GET', '/api/v1/me/subscriptions'),
        _api.json('GET', '/api/v1/me/referral'),
      ]);
      if (!mounted) return;
      final me = results[0];
      if (me['entitlement'] is Map) await _api.setEntitlement(me['entitlement'] as Map<String, dynamic>);
      setState(() {
        _offline = false;
        _me = me['user'] as Map<String, dynamic>?;
        _subs = [for (final s in (results[1]['subscriptions'] as List? ?? [])) s as Map<String, dynamic>];
        _referral = results[2];
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (!_api.isLoggedIn) {
        Navigator.pop(context); // logged out meanwhile (session expired)
        return;
      }
      setState(() {
        _offline = e.serverOffline;
        _error = e.serverOffline ? null : e.message;
      });
    }
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  static String _date(Object? v, {bool time = false}) {
    final d = v is String ? DateTime.tryParse(v)?.toLocal() : v is DateTime ? v : null;
    if (d == null) return '—';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final s = '${d.day} ${months[d.month - 1]} ${d.year}';
    return time ? '$s, ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}' : s;
  }

  static String _plan(String? productId, String? source) {
    switch (source) {
      case 'trial':
        return 'Free trial';
      case 'referral':
        return 'Referral bonus';
      case 'admin':
        return 'Pro (given by support)';
    }
    final id = productId ?? '';
    if (id.contains('year')) return 'Pro yearly';
    if (id.contains('month')) return 'Pro monthly';
    return id.isEmpty ? 'Pro' : id;
  }

  static String _source(String? s) => switch (s) {
        'google' => 'Google Play',
        'apple' => 'App Store',
        'admin' => 'Support',
        'trial' => 'Free trial',
        'referral' => 'Referral program',
        _ => s ?? '—',
      };

  static String _status(String? s) => switch (s) {
        'active' => 'Active',
        'grace' => 'Payment problem (still active)',
        'cancelled' => "Cancelled (won't renew)",
        'on_hold' => 'On hold',
        'paused' => 'Paused',
        'pending' => 'Pending',
        'expired' => 'Expired',
        'revoked' => 'Refunded / revoked',
        _ => s ?? '—',
      };

  // ---- Actions -------------------------------------------------------------------------

  Future<void> _editName() async {
    final c = TextEditingController(text: _api.user.value?.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 100,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null) return;
    try {
      await _api.updateName(name);
      await _load();
      _snack('Name saved');
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _changePassword() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => const _ChangePasswordDialog());
    if (ok == true) _snack('Password changed. Other phones were logged out.');
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
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
    if (ok != true) return;
    await _api.logout();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _deleteAccount() async {
    final pass = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.warning_amber, color: Theme.of(context).colorScheme.error),
        title: const Text('Delete your account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Your account and all cloud backups are deleted for good. '
                'Diary and tasks on this phone are kept.\n\n'
                'A Play Store subscription must be cancelled in the Play Store.'),
            const SizedBox(height: 12),
            TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Your password')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.deleteAccount(pass.text);
      if (!mounted) return;
      _snack('Your account was deleted');
      Navigator.pop(context);
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  String _inviteText() {
    final r = _referral!;
    final link = r['link'] as String?;
    return 'I use Abhi Utility: shake flashlight, app lock, reel counter, PDF scanner, diary, downloader and more. '
        'Register with my code ${r['code']} when you sign up!'
        '${link != null ? '\n$link' : ''}';
  }

  Future<void> _applyCode() async {
    final c = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.card_giftcard),
        title: const Text("Enter a friend's code"),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'Referral code'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Apply')),
        ],
      ),
    );
    if (code == null || code.trim().isEmpty) return;
    try {
      final j = await _api.json('POST', '/api/v1/me/referral/apply', body: {'code': code});
      if (j['entitlement'] is Map) await _api.setEntitlement(j['entitlement'] as Map<String, dynamic>);
      if (!mounted) return;
      setState(() => _referral = j['referral'] as Map<String, dynamic>?);
      _snack('🎉 Code applied. Thanks for joining through a friend!');
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  // ---- UI ----------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ValueListenableBuilder<AccountUser?>(
        valueListenable: _api.user,
        builder: (context, user, _) => user == null
            ? const Center(child: Text('Logged out'))
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    _header(user),
                    if (_offline) _notice(Icons.cloud_off, 'Server offline: showing what was saved on this phone.'),
                    if (_error != null) _notice(Icons.error_outline, _error!),
                    const SizedBox(height: 12),
                    _details(user),
                    const SizedBox(height: 12),
                    _subscription(),
                    const SizedBox(height: 12),
                    _referralCard(),
                    const SizedBox(height: 12),
                    _accountActions(),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _notice(IconData icon, String text) => Card(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: ListTile(
          leading: Icon(icon),
          title: Text(text),
          trailing: TextButton(onPressed: _load, child: const Text('Retry')),
        ),
      );

  Widget _header(AccountUser user) {
    final scheme = Theme.of(context).colorScheme;
    final name = user.name?.isNotEmpty == true ? user.name! : user.email.split('@').first;
    return Column(
      children: [
        const SizedBox(height: 8),
        CircleAvatar(
          radius: 40,
          backgroundColor: scheme.primaryContainer,
          child: Text(name[0].toUpperCase(),
              style: TextStyle(fontSize: 34, color: scheme.onPrimaryContainer, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 10),
        Text(name, style: Theme.of(context).textTheme.titleLarge),
        Text(user.email, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        ValueListenableBuilder<Entitlement?>(
          valueListenable: _api.entitlement,
          builder: (context, e, _) {
            final active = e?.active ?? false;
            return Chip(
              avatar: Icon(active ? Icons.workspace_premium : Icons.lock_outline,
                  size: 18, color: active ? Colors.amber.shade700 : scheme.error),
              label: Text(active ? (e!.isTrial ? 'Free trial' : 'Pro member') : 'No active plan'),
            );
          },
        ),
      ],
    );
  }

  Widget _section(String title, IconData icon, List<Widget> children, {Widget? action}) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                child: Row(
                  children: [
                    Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                    ?action,
                  ],
                ),
              ),
              ...children,
            ],
          ),
        ),
      );

  Widget _row(String label, String value, {VoidCallback? onTap, IconData? trailing}) => ListTile(
        dense: true,
        title: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        subtitle: Text(value, style: const TextStyle(fontSize: 15)),
        trailing: trailing == null ? null : Icon(trailing, size: 20),
        onTap: onTap,
      );

  Widget _details(AccountUser user) => _section('Your details', Icons.badge_outlined, [
        _row('Name', user.name?.isNotEmpty == true ? user.name! : 'Add your name', onTap: _editName, trailing: Icons.edit),
        _row('Email', user.email),
        _row('Member since', _date(_me?['createdAt'])),
        _row('Last login', _date(_me?['lastLoginAt'], time: true)),
        _row('Account ID', '#${user.id}'),
      ]);

  Widget _subscription() => ValueListenableBuilder<Entitlement?>(
        valueListenable: _api.entitlement,
        builder: (context, e, _) {
          final scheme = Theme.of(context).colorScheme;
          final active = e?.active ?? false;
          final subs = _subs;
          return _section(
            'Subscription',
            Icons.workspace_premium_outlined,
            [
              if (e == null)
                const ListTile(title: Text('Pull down to check'))
              else ...[
                _row('Plan', active ? _plan(e.productId, e.source) : (e.trialUsed ? 'Trial ended' : 'No plan')),
                if (active) _row('From', _source(e.source)),
                if (active)
                  _row(
                    e.expiresAt == null ? 'Valid' : (e.autoRenew ? 'Renews on' : 'Valid until'),
                    e.expiresAt == null ? 'Lifetime' : '${_date(e.expiresAt)}  ·  ${e.daysLeft} days left',
                  ),
                if (active && e.expiresAt != null) _row('Auto-renew', e.autoRenew ? 'On' : 'Off'),
                if (e.trialUsed) _row('Free trial', 'Used · ended ${_date(e.trialEndsAt)}'),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: FilledButton.tonalIcon(
                  onPressed: () => SubscriptionPage.open(context),
                  icon: Icon(active ? Icons.settings : Icons.star),
                  label: Text(active ? 'Manage / upgrade plan' : 'See plans'),
                ),
              ),
              if (subs != null && subs.isNotEmpty) ...[
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Text('History', style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
                ),
                for (final s in subs)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      switch (s['source']) {
                        'trial' => Icons.hourglass_bottom,
                        'referral' => Icons.card_giftcard,
                        'admin' => Icons.support_agent,
                        _ => Icons.receipt_long,
                      },
                    ),
                    title: Text(_plan(s['product_id'] as String?, s['source'] as String?)),
                    subtitle: Text('${_date(s['starts_at'] ?? s['created_at'])} → '
                        '${s['expires_at'] == null ? 'lifetime' : _date(s['expires_at'])}'
                        '${s['note'] != null ? '\n${s['note']}' : ''}'),
                    trailing: Text(_status(s['status'] as String?), style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ],
          );
        },
      );

  Widget _referralCard() {
    final r = _referral;
    final scheme = Theme.of(context).colorScheme;
    if (r == null) {
      return _section('Invite friends', Icons.card_giftcard, [
        ListTile(
          title: Text(_offline ? 'Needs the server: try again when it is online.' : 'Loading…'),
        ),
      ]);
    }
    final days = (r['rewardDays'] as num?)?.toInt() ?? 30;
    final reward = days == 30 ? '1 month' : '$days days';
    final friends = [for (final f in (r['friends'] as List? ?? [])) f as Map];
    return _section('Invite friends, get $reward free', Icons.card_giftcard, [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text(
          'Share your code. When a friend registers with it, you get $reward of Pro added to your plan.'
          '${((r['friendDays'] as num?) ?? 0) > 0 ? ' Your friend gets ${r['friendDays']} extra days too.' : ''}',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      ),
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Text('YOUR CODE', style: TextStyle(fontSize: 11, letterSpacing: 2, color: scheme.onPrimaryContainer)),
            const SizedBox(height: 4),
            SelectableText(
              r['code'] as String,
              style: TextStyle(
                  fontSize: 30, fontWeight: FontWeight.bold, letterSpacing: 4, color: scheme.onPrimaryContainer),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: r['code'] as String));
                  _snack('Code copied');
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _app.invokeMethod('shareText', {
                  'text': _inviteText(),
                  'subject': 'Try Abhi Utility',
                  'title': 'Invite a friend',
                }),
                icon: const Icon(Icons.share),
                label: const Text('Invite'),
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _stat('${r['invited'] ?? 0}', 'Friends joined'),
            _stat('${r['rewarded'] ?? 0}', 'Rewards'),
            _stat('${r['daysEarned'] ?? 0}', 'Days earned'),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          'Up to ${r['maxPerYear']} rewards a year · ${r['rewardsLeftThisYear']} left. '
          'Each friend must be new to Abhi Utility.',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ),
      if (friends.isNotEmpty) ...[
        const Divider(),
        for (final f in friends.take(20))
          ListTile(
            dense: true,
            leading: const Icon(Icons.person_outline),
            title: Text(f['name'] as String? ?? 'Friend'),
            subtitle: Text('Joined ${_date(f['joinedAt'])}'),
            trailing: Text(
              f['status'] == 'rewarded' ? '+${f['rewardDays']} days' : 'Yearly limit reached',
              style: TextStyle(color: f['status'] == 'rewarded' ? Colors.green.shade700 : scheme.onSurfaceVariant),
            ),
          ),
      ],
      if (r['referredBy'] is Map)
        ListTile(
          dense: true,
          leading: const Icon(Icons.handshake_outlined),
          title: Text('You joined with ${(r['referredBy'] as Map)['name'] ?? 'a friend'}\'s code'),
        )
      else if (r['canApplyCode'] == true)
        ListTile(
          leading: const Icon(Icons.redeem),
          title: const Text("Have a friend's code?"),
          subtitle: Text('Enter it within ${r['applyWithinDays']} days of registering'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _applyCode,
        ),
    ]);
  }

  Widget _stat(String value, String label) => Column(
        children: [
          Text(value, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      );

  Widget _accountActions() => _section('Account', Icons.manage_accounts_outlined, [
        ListTile(
          leading: const Icon(Icons.cloud_sync_outlined),
          title: const Text('Cloud backup'),
          subtitle: const Text('Back up or restore your diary and tasks'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => AccountPage.open(context),
        ),
        ListTile(
          leading: const Icon(Icons.password),
          title: const Text('Change password'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _changePassword,
        ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Log out'),
          onTap: _logout,
        ),
        ListTile(
          leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
          title: Text('Delete account', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          onTap: _deleteAccount,
        ),
      ]);
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _show = false;
  String? _error;

  Future<void> _save() async {
    if (_new.text.length < 8) return setState(() => _error = 'New password: at least 8 characters');
    if (_new.text != _confirm.text) return setState(() => _error = "The new passwords don't match");
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ApiClient.instance.changePassword(current: _current.text, newPassword: _new.text);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Change password'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _current, obscureText: !_show, decoration: const InputDecoration(labelText: 'Current password')),
              TextField(controller: _new, obscureText: !_show, decoration: const InputDecoration(labelText: 'New password')),
              TextField(controller: _confirm, obscureText: !_show, decoration: const InputDecoration(labelText: 'New password again')),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _show,
                onChanged: (v) => setState(() => _show = v ?? false),
                title: const Text('Show passwords'),
              ),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      );
}
