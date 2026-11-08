import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pin_pad.dart';

/// App Lock: pick apps and a rule (always locked / daily limit / hourly limit).
/// Enforcement happens natively in ReelCounterService.kt (Accessibility Service).
class AppLockPage extends StatefulWidget {
  const AppLockPage({super.key});

  @override
  State<AppLockPage> createState() => AppLockPageState();
}

class LockRule {
  LockRule.fromMap(Map m)
      : pkg = m['pkg'] as String,
        label = m['label'] as String,
        icon = m['icon'] as Uint8List?,
        mode = m['mode'] as String,
        minutes = m['minutes'] as int,
        usedSeconds = m['usedSeconds'] as int,
        limitSeconds = m['limitSeconds'] as int,
        locked = m['locked'] as bool,
        unlockAt = m['unlockAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['unlockAt'] as int);

  final String pkg;
  final String label;
  final Uint8List? icon;
  final String mode;
  final int minutes;
  final int usedSeconds;

  /// Allowed seconds in this window, including extra time given with the password.
  final int limitSeconds;
  final bool locked;
  final DateTime? unlockAt;
}

class InstalledApp {
  InstalledApp.fromMap(Map m)
      : pkg = m['pkg'] as String,
        label = m['label'] as String,
        icon = m['icon'] as Uint8List?,
        category = m['category'] as String,
        system = m['system'] as bool;

  final String pkg;
  final String label;
  final Uint8List? icon;

  /// "social", "game" or "other".
  final String category;

  /// Pre-installed (built-in) app.
  final bool system;
}

/// Filters in the app picker.
enum AppFilter {
  all('All'),
  social('Social media'),
  games('Games'),
  installed('Installed'),
  system('System');

  const AppFilter(this.label);
  final String label;

  bool matches(InstalledApp a) => switch (this) {
        AppFilter.all => true,
        AppFilter.social => a.category == 'social',
        AppFilter.games => a.category == 'game',
        AppFilter.installed => !a.system,
        AppFilter.system => a.system,
      };
}

class AppLockPageState extends State<AppLockPage> with WidgetsBindingObserver {
  static const _channel = MethodChannel('abhi_utility/applock');
  static const _reels = MethodChannel('abhi_utility/reels');

  bool _serviceEnabled = true;
  bool _loading = true;

  /// Password gate: the tab asks for the password before showing or changing locks.
  bool _hasPin = false;
  bool _fingerprint = true;
  bool _unlocked = false;
  List<LockRule> _rules = [];
  List<InstalledApp>? _apps;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
    // Leaving the app locks the tab again.
    if (state == AppLifecycleState.paused) relock();
  }

  void relock() {
    if (_unlocked && mounted) setState(() => _unlocked = false);
  }

  Future<void> refresh() async {
    try {
      final enabled = await _reels.invokeMethod<bool>('isEnabled') ?? false;
      final hasPin = await _channel.invokeMethod<bool>('hasPin') ?? false;
      final raw = await _channel.invokeListMethod<Map>('rules') ?? [];
      final fingerprint = await _channel.invokeMethod<bool>('fingerprintEnabled') ?? true;
      if (!mounted) return;
      setState(() {
        _hasPin = hasPin;
        _fingerprint = fingerprint;
        _serviceEnabled = enabled;
        _rules = raw.map(LockRule.fromMap).toList()..sort((a, b) => a.label.compareTo(b.label));
        _loading = false;
      });
    } on PlatformException {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<InstalledApp>> _loadApps() async {
    if (_apps != null) return _apps!;
    final raw = await _channel.invokeListMethod<Map>('apps') ?? [];
    _apps = raw.map(InstalledApp.fromMap).toList();
    return _apps!;
  }

  static String describe(String mode, int minutes) => switch (mode) {
        'daily' => '$minutes min per day',
        'hourly' => '$minutes min per hour',
        _ => 'Always locked',
      };

  static String _fmt(int seconds) {
    final m = seconds ~/ 60;
    return m >= 60 ? '${m ~/ 60}h ${m % 60}m' : '$m min';
  }

  String _status(LockRule r) {
    if (r.mode == 'block' && r.locked) return 'Locked';
    final window = r.mode == 'daily' ? 'today' : 'this hour';
    if (r.locked) {
      final t = r.unlockAt == null ? '' : TimeOfDay.fromDateTime(r.unlockAt!).format(context);
      return 'Locked · unlocks ${r.mode == 'daily' ? 'tomorrow ' : ''}at $t';
    }
    final left = r.limitSeconds - r.usedSeconds;
    final extra = r.limitSeconds - (r.mode == 'block' ? 0 : r.minutes * 60);
    return 'Used ${_fmt(r.usedSeconds)} $window · ${_fmt(left)} left'
        '${extra > 0 ? ' (incl. +${_fmt(extra)} extra)' : ''}';
  }

  Widget _icon(Uint8List? bytes, {double size = 40}) => bytes == null
      ? Icon(Icons.apps, size: size)
      : Image.memory(bytes, width: size, height: size, gaplessPlayback: true);

  // ---- Add / edit ------------------------------------------------------------------

  /// Pick one or more apps, then one rule for all of them.
  Future<void> _addApps({AppFilter filter = AppFilter.all, bool selectAll = false}) async {
    final apps = await showModalBottomSheet<List<InstalledApp>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _AppPicker(
        loadApps: _loadApps,
        lockedPkgs: _rules.map((r) => r.pkg).toSet(),
        iconBuilder: _icon,
        initialFilter: filter,
        selectAllInitially: selectAll,
      ),
    );
    if (apps == null || apps.isEmpty || !mounted) return;

    if (apps.length == 1) {
      final a = apps.first;
      await _editRule(a.pkg, a.label, a.icon, 'hourly', 10);
      return;
    }
    final result = await showModalBottomSheet<(String, int)?>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _RuleEditor(
        label: '${apps.length} apps',
        subtitle: apps.map((a) => a.label).join(', '),
        icon: const Icon(Icons.apps, size: 48),
        initialMode: 'hourly',
        initialMinutes: 10,
        existing: false,
      ),
    );
    if (result == null) return;
    await _channel.invokeMethod('setRules', {
      'pkgs': apps.map((a) => a.pkg).toList(),
      'mode': result.$1,
      'minutes': result.$2,
    });
    await refresh();
  }

  Future<void> _editRule(String pkg, String label, Uint8List? icon, String mode, int minutes,
      {bool existing = false}) async {
    final result = await showModalBottomSheet<(String, int)?>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _RuleEditor(
        label: label,
        icon: _icon(icon, size: 48),
        initialMode: mode,
        initialMinutes: minutes,
        existing: existing,
      ),
    );
    if (result == null) return;
    if (result.$1 == 'remove') {
      await _channel.invokeMethod('removeRule', {'pkg': pkg});
    } else {
      await _channel.invokeMethod('setRule', {'pkg': pkg, 'mode': result.$1, 'minutes': result.$2});
    }
    await refresh();
  }

  // ---- UI ----------------------------------------------------------------------------

  Future<void> _changePassword() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text('Change password')),
        body: _ChangePassword(channel: _channel),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final scheme = Theme.of(context).colorScheme;

    // 1. First time: create the password.
    if (!_hasPin) {
      return PinSetup(onDone: (pin) async {
        await _channel.invokeMethod('setPin', {'pin': pin});
        setState(() {
          _hasPin = true;
          _unlocked = true;
        });
        return null;
      });
    }
    // 2. Ask for it before showing or changing locks.
    if (!_unlocked) {
      return PinPad(
        title: 'App Lock is password protected',
        subtitle: 'Enter the password to see or change locks',
        onSubmit: (pin) async {
          final ok = await _channel.invokeMethod<bool>('checkPin', {'pin': pin}) ?? false;
          if (!ok) return 'Wrong password';
          setState(() => _unlocked = true);
          return null;
        },
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addApps,
        icon: const Icon(Icons.add),
        label: const Text('Lock apps'),
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            Row(
              children: [
                Icon(Icons.lock_open, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Unlocked with password',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
                TextButton(onPressed: _changePassword, child: const Text('Change password')),
                IconButton(
                  tooltip: 'Lock',
                  onPressed: relock,
                  icon: const Icon(Icons.lock),
                ),
              ],
            ),
            if (!_serviceEnabled)
              Card(
                color: scheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('App Lock needs the Abhi Utility service',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, color: scheme.onErrorContainer)),
                      const SizedBox(height: 8),
                      Text(
                        'Turn on "Abhi Utility reel counter" in Accessibility settings. '
                        'It is what notices when a locked app opens.',
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () => _reels.invokeMethod('openSettings'),
                        icon: const Icon(Icons.settings_accessibility),
                        label: const Text('Open Accessibility settings'),
                      ),
                    ],
                  ),
                ),
              ),
            Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.groups)),
                title: const Text('Lock all social media'),
                subtitle: const Text('Instagram, Facebook, YouTube, Snapchat, WhatsApp… in one go'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _addApps(filter: AppFilter.social, selectAll: true),
              ),
            ),
            Card(
              child: SwitchListTile(
                secondary: const CircleAvatar(child: Icon(Icons.fingerprint)),
                title: const Text('Fingerprint for extra time'),
                subtitle: const Text('Use your fingerprint instead of the password when a locked app asks'),
                value: _fingerprint,
                onChanged: (on) async {
                  setState(() => _fingerprint = on);
                  await _channel.invokeMethod('setFingerprintEnabled', {'on': on});
                },
              ),
            ),
            if (_rules.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Column(
                  children: [
                    Icon(Icons.lock_outline, size: 64, color: scheme.onSurfaceVariant),
                    const SizedBox(height: 16),
                    Text('No apps locked yet', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Tap "Lock apps" to block apps completely,\n'
                      'or limit it to a few minutes per day or per hour.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              )
            else
              for (final r in _rules)
                Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: _icon(r.icon),
                    title: Text(r.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(describe(r.mode, r.minutes)),
                        const SizedBox(height: 4),
                        if (!r.locked && r.limitSeconds > 0)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: (r.usedSeconds / r.limitSeconds).clamp(0, 1).toDouble(),
                              minHeight: 5,
                            ),
                          ),
                        const SizedBox(height: 4),
                        Text(_status(r),
                            style: TextStyle(
                              color: r.locked ? scheme.error : scheme.onSurfaceVariant,
                              fontWeight: r.locked ? FontWeight.w600 : null,
                            )),
                      ],
                    ),
                    trailing: Icon(r.locked ? Icons.lock : Icons.lock_clock,
                        color: r.locked ? scheme.error : scheme.primary),
                    onTap: () => _editRule(r.pkg, r.label, r.icon, r.mode, r.minutes, existing: true),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Searchable, filterable, multi-select list of installed apps.
class _AppPicker extends StatefulWidget {
  const _AppPicker({
    required this.loadApps,
    required this.lockedPkgs,
    required this.iconBuilder,
    this.initialFilter = AppFilter.all,
    this.selectAllInitially = false,
  });

  final Future<List<InstalledApp>> Function() loadApps;
  final Set<String> lockedPkgs;
  final Widget Function(Uint8List?, {double size}) iconBuilder;
  final AppFilter initialFilter;

  /// Tick every app of [initialFilter] once loaded ("lock all social media").
  final bool selectAllInitially;

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  late final Future<List<InstalledApp>> _future = widget.loadApps().then((apps) {
    if (widget.selectAllInitially) {
      _selected.addAll(_available(apps).where(widget.initialFilter.matches).map((a) => a.pkg));
    }
    return apps;
  });
  late AppFilter _filter = widget.initialFilter;
  String _query = '';
  final Set<String> _selected = {};

  List<InstalledApp> _available(List<InstalledApp> apps) =>
      apps.where((a) => !widget.lockedPkgs.contains(a.pkg)).toList();

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      builder: (context, scroll) => FutureBuilder<List<InstalledApp>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final all = _available(snap.data!);
          final q = _query.toLowerCase();
          final shown = all
              .where(_filter.matches)
              .where((a) => q.isEmpty || a.label.toLowerCase().contains(q))
              .toList();
          final allShownSelected = shown.isNotEmpty && shown.every((a) => _selected.contains(a.pkg));

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search apps',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              // Filter chips with counts.
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final f in AppFilter.values)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: FilterChip(
                          label: Text('${f.label} (${all.where(f.matches).length})'),
                          selected: _filter == f,
                          showCheckmark: false,
                          onSelected: (_) => setState(() => _filter = f),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: shown.isEmpty
                          ? null
                          : () => setState(() {
                                if (allShownSelected) {
                                  _selected.removeAll(shown.map((a) => a.pkg));
                                } else {
                                  _selected.addAll(shown.map((a) => a.pkg));
                                }
                              }),
                      icon: Icon(allShownSelected ? Icons.deselect : Icons.select_all),
                      label: Text(allShownSelected ? 'Unselect all' : 'Select all ${_filter == AppFilter.all ? '' : _filter.label}'),
                    ),
                    const Spacer(),
                    Text('${_selected.length} selected'),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: shown.isEmpty
                    ? const Center(child: Text('No apps here'))
                    : ListView.builder(
                        controller: scroll,
                        itemCount: shown.length,
                        itemBuilder: (context, i) {
                          final a = shown[i];
                          return CheckboxListTile(
                            value: _selected.contains(a.pkg),
                            onChanged: (v) => setState(() {
                              v == true ? _selected.add(a.pkg) : _selected.remove(a.pkg);
                            }),
                            secondary: widget.iconBuilder(a.icon, size: 36),
                            title: Text(a.label),
                            subtitle: Text(
                              [
                                if (a.category == 'social') 'Social media',
                                if (a.category == 'game') 'Game',
                                a.system ? 'System' : 'Installed',
                              ].join(' · '),
                            ),
                          );
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _selected.isEmpty
                          ? null
                          : () => Navigator.pop(
                                context,
                                all.where((a) => _selected.contains(a.pkg)).toList(),
                              ),
                      icon: const Icon(Icons.lock),
                      label: Text(_selected.isEmpty
                          ? 'Select apps to lock'
                          : 'Next: lock ${_selected.length} app${_selected.length == 1 ? '' : 's'}'),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Choose the lock rule: always / daily limit / hourly limit, and the minutes.
class _RuleEditor extends StatefulWidget {
  const _RuleEditor({
    required this.label,
    required this.icon,
    required this.initialMode,
    required this.initialMinutes,
    required this.existing,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final Widget icon;
  final String initialMode;
  final int initialMinutes;
  final bool existing;

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  static const _dailyOptions = [5, 10, 15, 30, 45, 60, 90, 120, 180];
  static const _hourlyOptions = [5, 10, 15, 20, 30, 45];

  late String _mode = widget.initialMode;
  late int _minutes = widget.initialMinutes;

  List<int> get _options => _mode == 'daily' ? _dailyOptions : _hourlyOptions;

  @override
  Widget build(BuildContext context) {
    // Keep the minutes valid when switching between daily and hourly.
    if (_mode != 'block' && !_options.contains(_minutes)) {
      _minutes = _mode == 'daily' ? 30 : 10;
    }
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                widget.icon,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Lock ${widget.label}', style: Theme.of(context).textTheme.titleLarge),
                      if (widget.subtitle != null)
                        Text(widget.subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'block', label: Text('Always'), icon: Icon(Icons.block)),
                ButtonSegment(value: 'daily', label: Text('Per day'), icon: Icon(Icons.today)),
                ButtonSegment(value: 'hourly', label: Text('Per hour'), icon: Icon(Icons.schedule)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 16),
            Text(
              switch (_mode) {
                'daily' => 'Use it for $_minutes min a day, then it locks until midnight.',
                'hourly' => 'Use it for $_minutes min in each hour, then it locks until the next hour.',
                _ => '${widget.label} will not open at all.',
              },
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (_mode != 'block') ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in _options)
                    ChoiceChip(
                      label: Text(m >= 60 && m % 60 == 0 ? '${m ~/ 60} h' : '$m min'),
                      selected: _minutes == m,
                      onSelected: (_) => setState(() => _minutes = m),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.pop(context, (_mode, _mode == 'block' ? 0 : _minutes)),
              child: Text(widget.existing ? 'Save' : 'Lock app'),
            ),
            if (widget.existing) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => Navigator.pop(context, ('remove', 0)),
                icon: const Icon(Icons.lock_open),
                label: const Text('Remove lock'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Change password: current password first, then the new one twice.
class _ChangePassword extends StatefulWidget {
  const _ChangePassword({required this.channel});
  final MethodChannel channel;

  @override
  State<_ChangePassword> createState() => _ChangePasswordState();
}

class _ChangePasswordState extends State<_ChangePassword> {
  String? _current;

  @override
  Widget build(BuildContext context) {
    if (_current == null) {
      return PinPad(
        title: 'Enter current password',
        onSubmit: (pin) async {
          final ok = await widget.channel.invokeMethod<bool>('checkPin', {'pin': pin}) ?? false;
          if (!ok) return 'Wrong password';
          setState(() => _current = pin);
          return null;
        },
      );
    }
    return PinSetup(
      title: 'Choose a new password',
      onDone: (pin) async {
        try {
          await widget.channel.invokeMethod('setPin', {'old': _current, 'pin': pin});
        } on PlatformException catch (e) {
          return e.message ?? 'Could not change password';
        }
        if (context.mounted) {
          final messenger = ScaffoldMessenger.of(context);
          Navigator.of(context).pop();
          messenger.showSnackBar(const SnackBar(content: Text('Password changed')));
        }
        return null;
      },
    );
  }
}
