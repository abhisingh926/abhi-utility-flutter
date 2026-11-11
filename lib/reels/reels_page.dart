import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../applock/app_lock_page.dart' show AppPicker, InstalledApp, InstalledApps;
import '../app_theme.dart';
import '../applock/accessibility_disclosure.dart';
import '../widgets/section_card.dart';

/// Daily reel report. Counting happens natively in ReelCounterService.kt
/// (an Accessibility Service); this page reads the stored counts.
class ReelsPage extends StatefulWidget {
  const ReelsPage({super.key});

  @override
  State<ReelsPage> createState() => ReelsPageState();
}

class ReelsPageState extends State<ReelsPage> with WidgetsBindingObserver {
  static const _channel = MethodChannel('abhi_utility/reels');
  static const _historyDays = 30;

  bool _enabled = false;
  Map<String, dynamic> _banking = const {};
  List<String>? _bankApps;
  bool _loading = true;
  Map<String, String> _names = {};

  /// Packages whose reels are counted.
  List<String> _counted = [];

  /// Installed apps for the picker (loaded the first time it opens).
  List<InstalledApp>? _installed;

  /// Newest first: (date, {package: count}).
  List<MapEntry<String, Map<String, int>>> _days = [];

  /// date -> {package: seconds spent}.
  Map<String, Map<String, int>> _seconds = {};
  bool _overlayEnabled = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from Instagram/YouTube or from Settings: reload.
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh() async {
    try {
      final enabled = await _channel.invokeMethod<bool>('isEnabled') ?? false;
      final raw = await _channel.invokeMapMethod<String, dynamic>('stats', {'days': _historyDays}) ?? {};
      final days = raw.entries
          .map((e) => MapEntry(
                e.key,
                (e.value as Map).map((k, v) => MapEntry(k as String, v as int)),
              ))
          .toList();
      final rawTime =
          await _channel.invokeMapMethod<String, dynamic>('timeStats', {'days': _historyDays}) ?? {};
      final seconds = rawTime.map((day, v) => MapEntry(
            day,
            (v as Map).map((k, s) => MapEntry(k as String, s as int)),
          ));
      final overlay = await _channel.invokeMethod<bool>('isOverlayEnabled') ?? true;
      final banking = await _channel.invokeMapMethod<String, dynamic>('bankingStatus') ?? {};
      final bankApps = await _channel.invokeListMethod<String>('bankingApps') ?? [];
      final counted = await _channel.invokeListMethod<String>('countedApps') ?? [];
      // Names for every app in the history too (apps counted earlier, then removed).
      final names = await _channel.invokeMapMethod<String, String>('appNames', {
            'pkgs': {
              for (final d in days) ...d.value.keys,
              for (final d in seconds.values) ...d.keys,
              ...bankApps,
            }.toList(),
          }) ??
          {};
      if (!mounted) return;
      setState(() {
        _banking = banking;
        _bankApps = bankApps;
        // Paused for a banking app still counts as on.
        _enabled = enabled || banking['paused'] == true;
        _names = names;
        _days = days;
        _seconds = seconds;
        _overlayEnabled = overlay;
        _counted = counted;
        _loading = false;
      });
    } on PlatformException {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _appName(String pkg) => _names[pkg] ?? pkg;

  static Color appColor(String name) => switch (name) {
        'Instagram' => const Color(0xFFE1306C),
        'YouTube' => const Color(0xFFFF0000),
        'Facebook' || 'Facebook Lite' => const Color(0xFF1877F2),
        'Snapchat' => const Color(0xFFFFC400),
        'Moj' || 'ShareChat' => const Color(0xFFFF7A00),
        'Josh' => const Color(0xFF7B2FF7),
        _ => Colors.teal,
      };

  static IconData appIcon(String name) => switch (name) {
        'Instagram' => Icons.camera_alt_outlined,
        'YouTube' => Icons.smart_display_outlined,
        'Facebook' || 'Facebook Lite' => Icons.facebook,
        'Snapchat' => Icons.chat_bubble_outline,
        _ => Icons.movie_outlined,
      };

  int _total(Map<String, int> m) => m.values.fold(0, (a, b) => a + b);

  static String formatTime(int seconds) {
    if (seconds > 0 && seconds < 60) return '<1 min';
    final m = seconds ~/ 60;
    if (m >= 60) return m % 60 == 0 ? '${m ~/ 60}h' : '${m ~/ 60}h ${m % 60}m';
    return '$m min';
  }

  /// Seconds per app summed over the newest [days] days.
  Map<String, int> _timeOver(int days) {
    final out = <String, int>{};
    for (final day in _seconds.entries.take(days)) {
      day.value.forEach((pkg, s) => out[pkg] = (out[pkg] ?? 0) + s);
    }
    return out;
  }

  /// Chart metric in the "Last 7 days" card.
  bool _weekShowsTime = false;

  Future<List<InstalledApp>> _loadApps() async {
    return _installed = await InstalledApps.load();
  }

  static Widget _pickerIcon(Uint8List? bytes, {double size = 40}) => bytes == null
      ? Icon(Icons.apps, size: size)
      : Image.memory(bytes, width: size, height: size, gaplessPlayback: true);

  Future<void> _chooseApps() async {
    final picked = await showModalBottomSheet<List<InstalledApp>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => AppPicker(
        loadApps: _loadApps,
        iconBuilder: _pickerIcon,
        initiallySelected: _counted.toSet(),
        confirmIcon: Icons.check,
        allowEmpty: true,
        confirmLabel: (n) => n == 0 ? "Don't count any app" : 'Count reels in $n app${n == 1 ? '' : 's'}',
      ),
    );
    if (picked == null || !mounted) return;
    // Keep chosen apps that aren't installed right now (e.g. TikTok): counted once installed.
    final installed = _installed!.map((a) => a.pkg).toSet();
    final pkgs = {
      ...picked.map((a) => a.pkg),
      ..._counted.where((p) => !installed.contains(p)),
    }.toList();
    await _channel.invokeMethod('setCountedApps', {'pkgs': pkgs});
    await refresh();
  }

  String _short(List<String> names) =>
      names.length <= 4 ? names.join(', ') : '${names.take(4).join(', ')} +${names.length - 4} more';

  /// One card with every setting: overlay, apps counted, banking pause.
  Widget _settingsCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final installed = _installed?.map((a) => a.pkg).toSet();
    // Before the installed list is loaded, show every chosen app.
    final shown = [for (final p in _counted) if (installed == null || installed.contains(p)) _appName(p)];
    final canToggle = _banking['canToggle'] == true;
    final usage = _banking['usageAccess'] == true;
    final paused = _banking['paused'] == true;
    final auto = _banking['auto'] != false;
    const divider = Divider(height: 1, indent: 72);
    return SectionCard(
      children: [
        SettingRow(
          icon: Icons.apps_rounded,
          title: 'Apps counted',
          subtitle: shown.isEmpty ? 'None chosen: reels are not counted' : _short(shown),
          trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          onTap: _chooseApps,
        ),
        if (_enabled) ...[
          divider,
          SettingRow(
            icon: Icons.picture_in_picture_alt_rounded,
            title: 'Counter on top of apps',
            subtitle: 'Reels and minutes today, while you scroll. Drag to move it; drag it to ✕ to hide it '
                'there (it keeps counting).',
            trailing: Switch(
              value: _overlayEnabled,
              onChanged: (v) async {
                await _channel.invokeMethod('setOverlayEnabled', {'enabled': v});
                setState(() => _overlayEnabled = v);
              },
            ),
          ),
          divider,
          // Banking apps refuse to work while the counter is on, so it pauses itself in them.
          SettingRow(
            icon: Icons.account_balance_rounded,
            title: 'Pause in banking apps',
            subtitle: canToggle
                ? 'Switches off while a banking or UPI app is open'
                : 'Switches off in banking apps; tap the notification to resume',
            trailing: Switch(
              value: auto,
              onChanged: (v) async {
                await _channel.invokeMethod('setBankingAuto', {'on': v});
                refresh();
              },
            ),
          ),
          if (auto)
            SettingRow(
              icon: Icons.list_alt_rounded,
              iconColor: scheme.onSurfaceVariant,
              title: 'Banking apps',
              subtitle: _bankApps == null
                  ? 'Finding them…'
                  : _bankApps!.isEmpty
                      ? 'None found. Tap to choose.'
                      : _short(_bankApps!.map(_appName).toList()),
              trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
              onTap: _chooseBankApps,
            ),
          if (canToggle && auto && !usage)
            WarningRow(
              text: 'Allow usage access so the counter turns back on as soon as you leave '
                  'the banking app (otherwise after 10 minutes).',
              onTap: () => _channel.invokeMethod('openUsageAccess'),
            ),
          if (paused)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.pause_circle_outline, color: scheme.onPrimaryContainer, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Paused for banking', style: TextStyle(color: scheme.onPrimaryContainer)),
                    ),
                    FilledButton.tonal(
                      onPressed: () async {
                        await _channel.invokeMethod('resumeFromBanking');
                        await Future.delayed(const Duration(milliseconds: 600));
                        refresh();
                      },
                      child: const Text('Resume'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _card({required Widget child, Color? color}) => SectionCard(color: color, children: [child]);

  Future<void> _chooseBankApps() async {
    final picked = await showModalBottomSheet<List<InstalledApp>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => AppPicker(
        loadApps: _loadApps,
        iconBuilder: _pickerIcon,
        initiallySelected: (_bankApps ?? const []).toSet(),
        confirmIcon: Icons.check,
        allowEmpty: true,
        confirmLabel: (n) => n == 0 ? 'No banking apps' : 'Pause in $n app${n == 1 ? '' : 's'}',
      ),
    );
    if (picked == null || !mounted) return;
    await _channel.invokeMethod('setBankingApps', {'pkgs': picked.map((a) => a.pkg).toList()});
    await refresh();
  }

  String _dayLabel(String key, int index) {
    if (index == 0) return 'Today';
    if (index == 1) return 'Yesterday';
    final d = DateTime.parse(key);
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${names[d.weekday - 1]}, ${d.day} ${months[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _hero(context),
          if (!_enabled) ...[const SizedBox(height: 12), _enableCard(context)],
          // Daily stats first; settings (changed rarely) at the bottom.
          if (_days.isNotEmpty) ...[
            const SectionTitle('Today by app'),
            _todayAppsCard(context),
            const SectionTitle('Insights'),
            _timeCard(context),
            const SizedBox(height: 12),
            _weekCard(context),
            if (_days.length > 1) ...[
              const SizedBox(height: 12),
              _historyCard(context),
            ],
          ],
          const SectionTitle('Settings'),
          _settingsCard(context),
          const SizedBox(height: 16),
          Text(
            'Counts each swipe to a new full-screen video in the chosen apps. Data stays on this phone.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Widget _enableCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Turn on the reel counter',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.bold,
                    )),
            const SizedBox(height: 8),
            Text(
              'Android needs Accessibility access to see when you swipe to the next reel.\n\n'
              '1. Tap the button below\n'
              '2. Installed apps → Abhi Utility reel counter\n'
              '3. Turn it on and tap Allow',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => openAccessibilityWithConsent(context),
              icon: const Icon(Icons.settings_accessibility),
              label: const Text('Open Accessibility settings'),
            ),
          ],
        ),
      ),
    );
  }

  /// Gradient header: reels and time today, compared with yesterday.
  Widget _hero(BuildContext context) {
    final hasDays = _days.isNotEmpty;
    final total = hasDays ? _total(_days.first.value) : 0;
    final yesterday = _days.length > 1 ? _total(_days[1].value) : 0;
    final totalSecs = hasDays ? _total(_seconds[_days.first.key] ?? {}) : 0;
    final yesterdaySecs = _seconds.length > 1 ? _total(_seconds.values.elementAt(1)) : 0;
    final paused = _banking['paused'] == true;
    final (statusText, statusColor) = !_enabled
        ? ('Counter is off', const Color(0xFFFFB020))
        : paused
            ? ('Paused for banking', const Color(0xFFFFB020))
            : ('Counting', const Color(0xFF4ADE80));

    Widget stat(String value, String label, String? note, int diff) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value,
                    style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w700)),
              ),
              Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13)),
              if (note != null) ...[
                const SizedBox(height: 6),
                Text(note,
                    style: TextStyle(
                      fontSize: 12,
                      color: diff > 0
                          ? const Color(0xFFFCA5A5)
                          : diff < 0
                              ? const Color(0xFF86EFAC)
                              : Colors.white.withValues(alpha: 0.7),
                    )),
              ],
            ],
          ),
        );

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
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
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.slow_motion_video_rounded, color: BrandColors.cyan, size: 24),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Today',
                    style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: statusColor),
                  ),
                  const SizedBox(width: 6),
                  Text(statusText, style: const TextStyle(color: Colors.white, fontSize: 12)),
                ]),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              stat('$total', 'reels watched',
                  yesterday > 0 || total > 0 ? _compare(total - yesterday, '$yesterday') : null, total - yesterday),
              Container(
                width: 1,
                height: 56,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                color: Colors.white.withValues(alpha: 0.15),
              ),
              stat(
                  formatTime(totalSecs),
                  'time spent',
                  yesterdaySecs > 0 || totalSecs > 0
                      ? _compare((totalSecs - yesterdaySecs) ~/ 60, formatTime(yesterdaySecs), unit: ' min')
                      : null,
                  (totalSecs - yesterdaySecs) ~/ 60),
            ],
          ),
        ],
      ),
    );
  }

  String _compare(int diff, String yesterday, {String unit = ''}) => diff == 0
      ? 'Same as yesterday'
      : '${diff.abs()}$unit ${diff > 0 ? 'more' : 'less'} than yesterday ($yesterday)';

  /// Reels and time per app today, most reels first.
  Widget _todayAppsCard(BuildContext context) {
    final today = _days.first.value;
    final todaySecs = _seconds[_days.first.key] ?? {};
    final total = _total(today);
    final pkgs = {...today.keys, ...todaySecs.keys}.toList()
      ..sort((a, b) => (today[b] ?? 0).compareTo(today[a] ?? 0));
    return _card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pkgs.isEmpty)
              const Text('No reels or time in these apps yet today 🎉')
            else
              for (final p in pkgs) _appRow(context, _appName(p), today[p] ?? 0, total, todaySecs[p] ?? 0),
          ],
        ),
      ),
    );
  }

  /// Time in the counted apps over longer periods (today is in the header): daily
  /// average, 7 and 30 days, and per app over 7 days.
  Widget _timeCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final week = _timeOver(7);
    final weekTotal = _total(week);
    final month = _total(_timeOver(30));
    final daysWithData = _seconds.values.take(7).where((d) => _total(d) > 0).length;
    final perApp = week.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));

    Widget period(String label, int secs) => Expanded(
          child: Column(
            children: [
              Text(formatTime(secs),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
        );

    return _card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Time spent', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            Row(
              children: [
                period('Avg per day', daysWithData > 0 ? weekTotal ~/ 7 : 0),
                Container(width: 1, height: 36, color: scheme.outlineVariant),
                period('Last 7 days', weekTotal),
                Container(width: 1, height: 36, color: scheme.outlineVariant),
                period('Last 30 days', month),
              ],
            ),
            if (perApp.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('By app · last 7 days', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              for (final e in perApp) _timeRow(context, _appName(e.key), e.value, weekTotal),
            ],
          ],
        ),
      ),
    );
  }

  Widget _timeRow(BuildContext context, String name, int seconds, int total) {
    final color = appColor(name);
    final share = total == 0 ? 0.0 : seconds / total;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(appIcon(name), color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w600))),
                    Text(formatTime(seconds), style: const TextStyle(fontWeight: FontWeight.bold)),
                    SizedBox(
                      width: 44,
                      child: Text('${(share * 100).round()}%',
                          textAlign: TextAlign.end,
                          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: share,
                    minHeight: 6,
                    color: color,
                    backgroundColor: color.withValues(alpha: 0.12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _appRow(BuildContext context, String name, int count, int total, int seconds) {
    final color = appColor(name);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.15),
            child: Icon(appIcon(name), color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w600))),
                    Text('$count reels · ${formatTime(seconds)}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: total == 0 ? 0 : count / total,
                    minHeight: 6,
                    color: color,
                    backgroundColor: color.withValues(alpha: 0.12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _weekCard(BuildContext context) {
    final week = _days.take(7).toList().reversed.toList(); // oldest -> today
    final showTime = _weekShowsTime;
    // Reels per day, or seconds per day.
    final totals = week.map((e) => showTime ? _total(_seconds[e.key] ?? {}) : _total(e.value)).toList();
    final maxVal = totals.fold(1, (a, b) => b > a ? b : a);
    final avg = totals.isEmpty ? 0 : (totals.reduce((a, b) => a + b) / totals.length).round();
    String label(int v) => showTime ? (v == 0 ? '0' : formatTime(v).replaceAll(' min', 'm')) : '$v';
    const dayNames = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final scheme = Theme.of(context).colorScheme;

    return _card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Last 7 days', style: Theme.of(context).textTheme.titleMedium)),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: false, label: Text('Reels')),
                    ButtonSegment(value: true, label: Text('Time')),
                  ],
                  selected: {showTime},
                  onSelectionChanged: (v) => setState(() => _weekShowsTime = v.first),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(showTime ? 'avg ${formatTime(avg)} / day' : 'avg $avg reels / day',
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            // Bars take whatever height is left after the labels, so a large
            // system font size can't push the chart past its box.
            SizedBox(
              height: 170,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < week.length; i++)
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            child: LayoutBuilder(builder: (context, box) {
                              final space = box.maxHeight;
                              final valueText = Text(label(totals[i]),
                                  maxLines: 1, overflow: TextOverflow.fade, softWrap: false,
                                  style: const TextStyle(fontSize: 11));
                              // Room left for the bar under its value label.
                              final labelHeight = MediaQuery.textScalerOf(context).scale(11) * 1.5 + 4;
                              final barRoom = space - labelHeight;
                              final bar = barRoom <= 0 ? 0.0 : barRoom * totals[i] / maxVal;
                              return Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: valueText)),
                                  const SizedBox(height: 4),
                                  Container(
                                    height: bar < 2 ? 2 : bar,
                                    margin: const EdgeInsets.symmetric(horizontal: 6),
                                    decoration: BoxDecoration(
                                      color: i == week.length - 1
                                          ? scheme.primary
                                          : scheme.primary.withValues(alpha: 0.45),
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                                    ),
                                  ),
                                ],
                              );
                            }),
                          ),
                          const SizedBox(height: 4),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(dayNames[DateTime.parse(week[i].key).weekday - 1],
                                maxLines: 1, style: TextStyle(color: scheme.onSurfaceVariant)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _historyCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Previous days', style: Theme.of(context).textTheme.titleMedium),
            ),
            // Today is in the header; yesterday always, older days only if something was counted.
            for (var i = 1; i < _days.length; i++)
              if (i == 1 || _total(_days[i].value) > 0 || _total(_seconds[_days[i].key] ?? {}) > 0)
                ListTile(
                  dense: true,
                  title: Text(_dayLabel(_days[i].key, i)),
                  subtitle: _days[i].value.isEmpty
                      ? null
                      : Text(
                          (_days[i].value.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
                              .map((e) => '${_appName(e.key)} ${e.value}')
                              .join(' · '),
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${_total(_days[i].value)} reels',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      Text(formatTime(_total(_seconds[_days[i].key] ?? {})),
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
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
