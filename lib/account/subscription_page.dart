import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'account_page.dart';
import 'api_client.dart';
import 'subscription_service.dart';

String _day(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

/// "Subscription" screen: trial / plan status, plans, restore.
class SubscriptionPage extends StatelessWidget {
  const SubscriptionPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SubscriptionPage()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Subscription')),
      body: const PaywallView(),
    );
  }
}

/// Shown instead of a feature when the user has no trial or subscription, and
/// inside [SubscriptionPage]. Logged out → register for the free trial;
/// trial over → subscribe through the store.
class PaywallView extends StatefulWidget {
  const PaywallView({super.key, this.locked = false});

  /// True when it covers a feature (wording: "this feature is locked").
  final bool locked;

  @override
  State<PaywallView> createState() => _PaywallViewState();
}

class _PaywallViewState extends State<PaywallView> {
  final _api = ApiClient.instance;
  final _subs = SubscriptionService.instance;
  bool _checking = false;
  String? _checkError;

  @override
  void initState() {
    super.initState();
    _api.load().then((_) {
      if (_api.isLoggedIn) {
        _check();
        _subs.loadProducts();
      }
    });
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _checkError = null;
    });
    try {
      await _api.refreshAccount();
    } on ApiException catch (e) {
      if (mounted) setState(() => _checkError = e.message);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _openAccount({required bool register}) async {
    await AccountPage.open(context, register: register, closeOnLogin: true);
    if (_api.isLoggedIn) _subs.loadProducts();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_api.user, _api.entitlement, _subs.products, _subs.busy, _subs.error]),
      builder: (context, _) {
        final user = _api.user.value;
        final ent = _api.entitlement.value;
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: user == null ? _loggedOut(context) : _loggedIn(context, ent),
              ),
            ),
          ),
        );
      },
    );
  }

  // ---- Not registered: the trial needs an account ------------------------------------

  List<Widget> _loggedOut(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return [
      Icon(widget.locked ? Icons.lock_outline : Icons.card_giftcard, size: 64, color: scheme.primary),
      const SizedBox(height: 12),
      Text('Get ${_subs.trialLabel} free', textAlign: TextAlign.center, style: t.headlineSmall),
      const SizedBox(height: 8),
      Text(
        widget.locked
            ? 'Register a free account to unlock every feature for ${_subs.trialDays} days. No payment needed.'
            : 'Register a free account to start your ${_subs.trialDays}-day free trial. No payment needed.',
        textAlign: TextAlign.center,
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 20),
      const _Perks(),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: () => _openAccount(register: true),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Register & start free trial'),
      ),
      TextButton(
        onPressed: () => _openAccount(register: false),
        child: const Text('Already have an account? Log in'),
      ),
    ];
  }

  // ---- Registered: status + plans ----------------------------------------------------

  List<Widget> _loggedIn(BuildContext context, Entitlement? ent) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final active = ent?.active ?? false;

    if (ent == null) {
      return [
        if (_checking) const Center(child: CircularProgressIndicator()) else ...[
          Icon(Icons.cloud_off, size: 56, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(_checkError ?? 'Could not check your subscription.', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: _check, child: const Text('Try again')),
        ],
      ];
    }

    final String title;
    final String subtitle;
    final IconData icon;
    if (active && ent.isTrial) {
      final d = ent.daysLeft ?? 0;
      icon = Icons.hourglass_bottom;
      title = 'Free trial: $d ${d == 1 ? 'day' : 'days'} left';
      subtitle = 'Your trial ends on ${_day(ent.expiresAt!)}. Subscribe any time to keep every feature after that.';
    } else if (active) {
      icon = Icons.workspace_premium;
      title = 'You have Pro';
      subtitle = ent.expiresAt == null
          ? 'Lifetime access.'
          : '${ent.autoRenew ? 'Renews' : 'Active until'} ${_day(ent.expiresAt!)}.'
              '${ent.source == 'google' ? ' Manage or cancel it in the Play Store → Subscriptions.' : ''}';
    } else {
      icon = widget.locked ? Icons.lock_outline : Icons.timer_off_outlined;
      title = ent.trialUsed ? 'Your free trial has ended' : 'Subscribe to continue';
      subtitle = ent.trialUsed && ent.trialEndsAt != null
          ? 'It ended on ${_day(ent.trialEndsAt!)}. Choose a plan to keep using all features.'
          : 'Choose a plan to use all features.';
    }

    return [
      Icon(icon, size: 64, color: active ? scheme.primary : scheme.error),
      const SizedBox(height: 12),
      Text(title, textAlign: TextAlign.center, style: t.headlineSmall),
      const SizedBox(height: 8),
      Text(subtitle, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
      if (!(active && !ent.isTrial)) ...[
        const SizedBox(height: 20),
        const _Perks(),
        const SizedBox(height: 16),
        ..._plans(context),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _subs.busy.value ? null : _subs.restore,
          child: const Text('Restore purchase'),
        ),
      ],
      if (_subs.error.value != null) ...[
        const SizedBox(height: 8),
        Text(_subs.error.value!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
      ],
      const SizedBox(height: 8),
      TextButton.icon(
        onPressed: _checking ? null : _check,
        icon: const Icon(Icons.refresh, size: 18),
        label: Text(_checking ? 'Checking…' : 'Refresh status'),
      ),
    ];
  }

  List<Widget> _plans(BuildContext context) {
    final list = _subs.products.value;
    if (list.isEmpty) {
      return [if (_subs.error.value == null) const Center(child: CircularProgressIndicator())];
    }
    return [
      for (final p in list) ...[
        _PlanTile(product: p, enabled: !_subs.busy.value, onBuy: () => _subs.buy(p)),
        const SizedBox(height: 10),
      ],
      if (_subs.busy.value) const LinearProgressIndicator(),
    ];
  }
}

class _PlanTile extends StatelessWidget {
  const _PlanTile({required this.product, required this.enabled, required this.onBuy});
  final ProductDetails product;
  final bool enabled;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    final yearly = product.id.contains('year');
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: yearly ? scheme.primaryContainer : null,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Icon(yearly ? Icons.calendar_month : Icons.calendar_today),
        title: Text(yearly ? 'Yearly' : 'Monthly', style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(yearly ? 'Best value' : 'Cancel any time'),
        trailing: FilledButton(onPressed: enabled ? onBuy : null, child: Text(product.price)),
        onTap: enabled ? onBuy : null,
      ),
    );
  }
}

class _Perks extends StatelessWidget {
  const _Perks();

  @override
  Widget build(BuildContext context) {
    const perks = [
      (Icons.apps, 'Every feature: VPN, PDF tools, Diary, App Lock, Downloader…'),
      (Icons.cloud_sync_outlined, 'Cloud backup of your diary and tasks'),
      (Icons.devices, 'Works on all your phones with one account'),
    ];
    return Column(
      children: [
        for (final (icon, text) in perks)
          ListTile(dense: true, leading: Icon(icon, color: Colors.green), title: Text(text)),
      ],
    );
  }
}

/// Home page card: "register for a free month" / "N days of trial left" /
/// "trial ended". Hidden for paying users.
class SubscriptionBanner extends StatelessWidget {
  const SubscriptionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final api = ApiClient.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([api.user, api.entitlement]),
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final ent = api.entitlement.value;
        final trialText = SubscriptionService.instance.trialLabel;
        final IconData icon;
        final String title;
        final String subtitle;
        var warn = false;
        if (api.user.value == null) {
          icon = Icons.card_giftcard;
          title = 'Get $trialText free';
          subtitle = 'Register to start your free trial and unlock every feature';
        } else if (ent == null) {
          return const SizedBox.shrink();
        } else if (ent.active && ent.isTrial) {
          final d = ent.daysLeft ?? 0;
          icon = Icons.hourglass_bottom;
          title = 'Free trial · $d ${d == 1 ? 'day' : 'days'} left';
          subtitle = 'Tap to see plans';
          warn = d <= 3;
        } else if (ent.active) {
          return const SizedBox.shrink();
        } else {
          icon = Icons.lock_outline;
          title = ent.trialUsed ? 'Your free trial has ended' : 'Subscribe to use the features';
          subtitle = 'Tap to choose a plan';
          warn = true;
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            margin: EdgeInsets.zero,
            color: warn ? scheme.errorContainer : scheme.tertiaryContainer,
            child: ListTile(
              leading: Icon(icon, color: warn ? scheme.onErrorContainer : scheme.onTertiaryContainer),
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(subtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => api.user.value == null
                  ? AccountPage.open(context, register: true, closeOnLogin: true)
                  : SubscriptionPage.open(context),
            ),
          ),
        );
      },
    );
  }
}
