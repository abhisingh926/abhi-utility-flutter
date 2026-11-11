import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../diary/diary_lock.dart';
import '../store_build.dart';
import 'pin_pad.dart';
import 'accessibility_disclosure.dart';
import '../widgets/section_card.dart';

/// App Lock: pick apps and a rule (always locked / daily limit / hourly limit).
/// Enforcement happens natively in ReelCounterService.kt (Accessibility Service).
class AppLockPage extends StatefulWidget {
  const AppLockPage({super.key, this.active = false});

  /// True while the App Lock tab is on screen (only then does it ask for the password).
  final bool active;

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

/// The installed apps for the pickers, loaded once and shared by every page
/// (App Lock, Reels). [prefetch] starts loading in the background so the picker
/// opens straight away.
class InstalledApps {
  static const _channel = MethodChannel('abhi_utility/applock');
  static Future<List<InstalledApp>>? _future;
  static DateTime? _loadedAt;

  static Future<List<InstalledApp>> load() => _future ??= _fetch();

  /// Reloads if the list is older than a minute (an app may have been installed);
  /// icons are cached on the Android side, so a reload is quick.
  static void prefetch() {
    final at = _loadedAt;
    if (_future == null || (at != null && DateTime.now().difference(at) > const Duration(minutes: 1))) {
      final next = _fetch();
      // Keep serving the old list until the new one is ready.
      next.then((_) => _future = next, onError: (_) {});
      _future ??= next;
    }
  }

  static Future<List<InstalledApp>> _fetch() async {
    try {
      final raw = await _channel.invokeListMethod<Map>('apps') ?? [];
      _loadedAt = DateTime.now();
      return raw.map(InstalledApp.fromMap).toList();
    } catch (e) {
      _future = null; // try again next time
      rethrow;
    }
  }
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
  bool _bioAvailable = false;
  bool _bioPrompted = false; // ask for the fingerprint once per lock, only while the tab is shown

  /// Only the App Lock password/fingerprint opens this (and the Diary with it);
  /// the Diary password does not. Leaving the app locks both.
  bool get _unlocked => DiaryLock.appLockUnlocked.value;
  List<LockRule> _rules = [];

  /// Uninstall protection: {on, admin, guard, hasPassword} from the native side.
  Map<String, bool> _protection = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DiaryLock.appLockUnlocked.addListener(_onLockChanged);
    refresh();
    // Load the app list now, so "Add apps" / "Lock all social media" opens at once.
    InstalledApps.prefetch();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DiaryLock.appLockUnlocked.removeListener(_onLockChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  void _onLockChanged() {
    if (!_unlocked) _bioPrompted = false;
    if (mounted) setState(() {});
  }

  /// Lock button: locks App Lock and the Diary.
  void relock() => DiaryLock.lockNow();

  bool get _useFingerprint => _fingerprint && _bioAvailable;

  Future<void> _unlockWithFingerprint() async {
    _bioPrompted = true;
    if (await DiaryLock.authenticate(reason: 'Unlock App Lock and Diary')) DiaryLock.unlockAll();
  }

  Future<void> refresh() async {
    try {
      final enabled = await _reels.invokeMethod<bool>('isEnabled') ?? false;
      final hasPin = await _channel.invokeMethod<bool>('hasPin') ?? false;
      final raw = await _channel.invokeListMethod<Map>('rules') ?? [];
      final fingerprint = await _channel.invokeMethod<bool>('fingerprintEnabled') ?? true;
      final bioAvailable = await DiaryLock.biometricAvailable();
      final protection = await _channel.invokeMapMethod<String, bool>('protectionStatus') ?? const {};
      if (!mounted) return;
      setState(() {
        _protection = protection;
        _hasPin = hasPin;
        _fingerprint = fingerprint;
        _bioAvailable = bioAvailable;
        _serviceEnabled = enabled;
        _rules = raw.map(LockRule.fromMap).toList()..sort((a, b) => a.label.compareTo(b.label));
        _loading = false;
      });
    } on PlatformException {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<InstalledApp>> _loadApps() => InstalledApps.load();

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
      builder: (context) => AppPicker(
        loadApps: _loadApps,
        excludedPkgs: _rules.map((r) => r.pkg).toSet(),
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

  // ---- Uninstall protection ---------------------------------------------------------

  Future<void> _setProtection(bool on) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!on) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.shield_outlined, size: 40),
          title: const Text('Turn off uninstall protection?'),
          content: const Text('Anyone will be able to uninstall Abhi Utility again.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Turn off')),
          ],
        ),
      );
      if (yes != true) return;
      final s = await _channel.invokeMapMethod<String, bool>('disableProtection') ?? const {};
      if (mounted) setState(() => _protection = s);
      messenger.showSnackBar(const SnackBar(content: Text('Uninstall protection is off')));
      return;
    }

    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.shield_outlined, size: 40),
        title: const Text('Protect Abhi Utility from being uninstalled'),
        content: const Text(
          "Children won't be able to uninstall Abhi Utility, force-stop it, or turn off its "
          'accessibility service. Those screens will ask for the App Lock password '
          '(or your fingerprint).\n\n'
          'On the next screen Android asks to activate a "device admin app": tap Activate.\n\n'
          'To uninstall later, turn this switch off first.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
        ],
      ),
    );
    if (go != true) return;
    DiaryLock.openingSystemScreen = true; // Android's "Activate device admin" screen mustn't lock us
    try {
      final s = await _channel.invokeMapMethod<String, bool>('enableProtection') ?? const {};
      if (!mounted) return;
      setState(() => _protection = s);
      messenger.showSnackBar(SnackBar(
        content: Text(s['on'] == true
            ? '🛡️ Uninstall protection is on'
            : "Not turned on: tap Activate on Android's screen to protect the app"),
      ));
    } on PlatformException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message ?? 'Could not turn on protection')));
    } finally {
      DiaryLock.openingSystemScreen = false;
    }
  }

  /// "Security" card: fingerprint unlock + uninstall protection (and its warnings).
  Widget _securityCard(ColorScheme scheme) {
    final on = _protection['on'] == true;
    final admin = _protection['admin'] == true;
    final guard = _protection['guard'] == true;
    return SectionCard(
      children: [
        SettingRow(
          icon: Icons.fingerprint,
          title: 'Fingerprint unlock',
          subtitle: _bioAvailable
              ? 'Instead of the password, here and for extra time'
              : 'Set up a fingerprint in phone settings first',
          trailing: Switch(
            value: _fingerprint,
            onChanged: (v) async {
              setState(() => _fingerprint = v);
              await _channel.invokeMethod('setFingerprintEnabled', {'on': v});
            },
          ),
        ),
        // Not in the Play build: Play only allows blocking uninstalls in parental-control apps.
        if (!kPlayStore) ...[
        const Divider(height: 1, indent: 72),
        SettingRow(
          icon: on ? Icons.shield : Icons.shield_outlined,
          title: 'Uninstall protection',
          subtitle: on ? 'Uninstalling needs the App Lock password' : 'Anyone can uninstall Abhi Utility',
          trailing: Switch(value: on, onChanged: _setProtection),
        ),
        if (on && !admin)
          WarningRow(
            text: "Android's uninstall block is off. Tap to activate it again.",
            onTap: () => _setProtection(true),
          ),
        if (on && !guard)
          WarningRow(
            text: 'Settings are not protected. Turn on "Abhi Utility reel counter" in Accessibility.',
            onTap: () => openAccessibilityWithConsent(context),
          ),
        ],
      ],
    );
  }

  /// Gradient header: status, counts, password + lock buttons.
  Widget _header(ColorScheme scheme) {
    final lockedNow = _rules.where((r) => r.locked).length;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [BrandColors.indigo, BrandColors.navy],
        ),
        boxShadow: [
          BoxShadow(color: BrandColors.navy.withValues(alpha: 0.25), blurRadius: 18, offset: const Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.lock_person_rounded, color: BrandColors.cyan, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('App Lock',
                        style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Row(children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _serviceEnabled ? const Color(0xFF4ADE80) : const Color(0xFFFFB020),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(_serviceEnabled ? 'Protection active' : 'Service is off',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13)),
                      ),
                    ]),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              _HeaderStat(value: '${_rules.length}', label: _rules.length == 1 ? 'app with a lock' : 'apps with a lock'),
              Container(width: 1, height: 32, color: Colors.white.withValues(alpha: 0.15)),
              _HeaderStat(value: '$lockedNow', label: 'locked right now'),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.14),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  onPressed: _changePassword,
                  icon: const Icon(Icons.password_rounded, size: 18),
                  label: const Text('Password'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: BrandColors.cyan,
                    foregroundColor: BrandColors.navy,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  onPressed: relock,
                  icon: const Icon(Icons.lock_rounded, size: 18),
                  label: const Text('Lock now'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// One locked app: icon, rule, usage bar, status pill.
  Widget _ruleCard(LockRule r, ColorScheme scheme) {
    final progress = r.limitSeconds > 0 ? (r.usedSeconds / r.limitSeconds).clamp(0.0, 1.0) : 1.0;
    final barColor = r.locked
        ? scheme.error
        : progress > 0.8
            ? const Color(0xFFF59E0B)
            : scheme.primary;
    return SectionCard(
      onTap: () => _editRule(r.pkg, r.label, r.icon, r.mode, r.minutes, existing: true),
      padding: const EdgeInsets.all(14),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(14),
              ),
              child: _icon(r.icon, size: 36),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(r.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                      _StatusPill(locked: r.locked),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(describe(r.mode, r.minutes),
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                  if (r.mode != 'block') ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: progress.toDouble(),
                        minHeight: 6,
                        color: barColor,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(_status(r),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: r.locked ? scheme.error : scheme.onSurfaceVariant,
                        fontWeight: r.locked ? FontWeight.w600 : null,
                      )),
                ],
              ),
            ),
          ],
        ),
      ],
    );
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
        setState(() => _hasPin = true);
        DiaryLock.unlockAll();
        return null;
      });
    }
    // 2. Ask for it before showing or changing locks.
    if (!_unlocked) {
      // Opened: ask for the fingerprint straight away (never while another tab is
      // shown — every tab is built in the background); password as fallback.
      if (widget.active && _useFingerprint && !_bioPrompted) {
        _bioPrompted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _unlockWithFingerprint());
      }
      return Column(
        children: [
          Expanded(
            child: PinPad(
              title: 'App Lock is password protected',
              subtitle: _useFingerprint
                  ? 'Use your fingerprint or the App Lock password'
                  : 'Enter the App Lock password',
              onSubmit: (pin) async {
                if (!await DiaryLock.checkAppLockPassword(pin)) return 'Wrong password';
                DiaryLock.unlockAll(); // opens the Diary too
                return null;
              },
            ),
          ),
          if (_useFingerprint)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: OutlinedButton.icon(
                onPressed: _unlockWithFingerprint,
                icon: const Icon(Icons.fingerprint, size: 28),
                label: const Text('Use fingerprint'),
              ),
            ),
        ],
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          children: [
            _header(scheme),
            if (!_serviceEnabled) ...[
              const SizedBox(height: 12),
              SectionCard(
                color: scheme.errorContainer,
                children: [
                  SettingRow(
                    icon: Icons.warning_amber_rounded,
                    iconColor: scheme.error,
                    title: 'App Lock is not running',
                    subtitle: 'Turn on "Abhi Utility reel counter" in Accessibility. It notices when a locked app opens.',
                    trailing: Icon(Icons.chevron_right, color: scheme.onErrorContainer),
                    onTap: () => openAccessibilityWithConsent(context),
                  ),
                ],
              ),
            ],
            // Locked apps first; quick action and security settings (changed rarely) below.
            SectionTitle(_rules.isEmpty ? 'Locked apps' : 'Locked apps · ${_rules.length}'),
            if (_rules.isEmpty)
              SectionCard(
                padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
                children: [
                  Icon(Icons.lock_outline_rounded, size: 48, color: scheme.primary),
                  const SizedBox(height: 12),
                  Text('No apps locked yet',
                      textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    'Tap "Lock apps" to block an app completely, or allow a few minutes per day or per hour.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              )
            else
              for (final r in _rules)
                Padding(padding: const EdgeInsets.only(bottom: 10), child: _ruleCard(r, scheme)),
            const SectionTitle('Quick action'),
            SectionCard(
              children: [
                SettingRow(
                  icon: Icons.groups_rounded,
                  title: 'Lock all social media',
                  subtitle: 'Instagram, YouTube, Snapchat, WhatsApp… in one go',
                  trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                  onTap: () => _addApps(filter: AppFilter.social, selectAll: true),
                ),
              ],
            ),
            const SectionTitle('Security'),
            _securityCard(scheme),
          ],
        ),
      ),
    );
  }

}

/// Searchable, filterable, multi-select list of installed apps (App Lock, reel counter).
/// Pops with the ticked apps.
class AppPicker extends StatefulWidget {
  const AppPicker({
    super.key,
    required this.loadApps,
    required this.iconBuilder,
    this.excludedPkgs = const {},
    this.initiallySelected = const {},
    this.initialFilter = AppFilter.all,
    this.selectAllInitially = false,
    this.confirmLabel,
    this.confirmIcon = Icons.lock,
    this.allowEmpty = false,
  });

  final Future<List<InstalledApp>> Function() loadApps;
  final Widget Function(Uint8List?, {double size}) iconBuilder;

  /// Not listed (e.g. apps that already have a lock rule).
  final Set<String> excludedPkgs;

  /// Ticked when the picker opens.
  final Set<String> initiallySelected;
  final AppFilter initialFilter;

  /// Tick every app of [initialFilter] once loaded ("lock all social media").
  final bool selectAllInitially;

  /// Button text for the number of ticked apps (default: "Next: lock N apps").
  final String Function(int count)? confirmLabel;
  final IconData confirmIcon;

  /// The button works with nothing ticked.
  final bool allowEmpty;

  @override
  State<AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<AppPicker> {
  late final Future<List<InstalledApp>> _future = widget.loadApps().then((apps) {
    if (widget.selectAllInitially) {
      _selected.addAll(_available(apps).where(widget.initialFilter.matches).map((a) => a.pkg));
    }
    return apps;
  });
  late AppFilter _filter = widget.initialFilter;
  String _query = '';
  late final Set<String> _selected = {...widget.initiallySelected};

  List<InstalledApp> _available(List<InstalledApp> apps) =>
      apps.where((a) => !widget.excludedPkgs.contains(a.pkg)).toList();

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      builder: (context, scroll) => FutureBuilder<List<InstalledApp>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Could not list your apps. Close this and try again.', textAlign: TextAlign.center),
              ),
            );
          }
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
          // Ticked apps that are installed (initiallySelected may name apps that aren't).
          final picked = all.where((a) => _selected.contains(a.pkg)).length;

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
                    Text('$picked selected'),
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
                      onPressed: picked == 0 && !widget.allowEmpty
                          ? null
                          : () => Navigator.pop(
                                context,
                                all.where((a) => _selected.contains(a.pkg)).toList(),
                              ),
                      icon: Icon(widget.confirmIcon),
                      label: Text(widget.confirmLabel?.call(picked) ??
                          (picked == 0 ? 'Select apps to lock' : 'Next: lock $picked app${picked == 1 ? '' : 's'}')),
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

// ---- App Lock header pieces -------------------------------------------------------------





class _HeaderStat extends StatelessWidget {
  const _HeaderStat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          children: [
            Text(value, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700)),
            Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12)),
          ],
        ),
      );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.locked});
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = locked ? scheme.error : const Color(0xFF16A34A);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(locked ? Icons.lock_rounded : Icons.lock_open_rounded, size: 13, color: c),
          const SizedBox(width: 4),
          Text(locked ? 'Locked' : 'Open', style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
