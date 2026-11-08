import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../applock/app_lock_page.dart' show AppPicker, InstalledApp;

/// Daily reel report. Counting happens natively in ReelCounterService.kt
/// (an Accessibility Service); this page reads the stored counts.
class ReelsPage extends StatefulWidget {
  const ReelsPage({super.key});

  @override
  State<ReelsPage> createState() => ReelsPageState();
}

class ReelsPageState extends State<ReelsPage> with WidgetsBindingObserver {
  static const _channel = MethodChannel('abhi_utility/reels');
  static const _appsChannel = MethodChannel('abhi_utility/applock');
  static const _historyDays = 30;

  bool _enabled = false;
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
      final counted = await _channel.invokeListMethod<String>('countedApps') ?? [];
      // Names for every app in the history too (apps counted earlier, then removed).
      final names = await _channel.invokeMapMethod<String, String>('appNames', {
            'pkgs': {
              for (final d in days) ...d.value.keys,
              for (final d in seconds.values) ...d.keys,
            }.toList(),
          }) ??
          {};
      if (!mounted) return;
      setState(() {
        _enabled = enabled;
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
    final m = seconds ~/ 60;
    if (m >= 60) return '${m ~/ 60}h ${m % 60}m';
    return '$m min';
  }

  Future<List<InstalledApp>> _loadApps() async {
    if (_installed != null) return _installed!;
    final raw = await _appsChannel.invokeListMethod<Map>('apps') ?? [];
    return _installed = raw.map(InstalledApp.fromMap).toList();
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

  Widget _appsCard(BuildContext context) {
    final installed = _installed?.map((a) => a.pkg).toSet();
    // Before the installed list is loaded, show every chosen app.
    final shown = [for (final p in _counted) if (installed == null || installed.contains(p)) _appName(p)];
    return Card(
      child: ListTile(
        leading: const Icon(Icons.checklist),
        title: const Text('Apps counted'),
        subtitle: Text(
          shown.isEmpty
              ? 'No apps chosen: reels are not counted'
              : shown.length <= 4
                  ? shown.join(', ')
                  : '${shown.take(4).join(', ')} +${shown.length - 4} more',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _chooseApps,
      ),
    );
  }

  Widget _overlayCard(BuildContext context) {
    return Card(
      child: SwitchListTile(
        secondary: const Icon(Icons.picture_in_picture_alt_outlined),
        title: const Text('Show counter on top of apps'),
        subtitle: const Text('Reels and minutes today, shown while you use Instagram, YouTube, etc.'),
        value: _overlayEnabled,
        onChanged: (v) async {
          await _channel.invokeMethod('setOverlayEnabled', {'enabled': v});
          setState(() => _overlayEnabled = v);
        },
      ),
    );
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
        padding: const EdgeInsets.all(16),
        children: [
          if (!_enabled) _enableCard(context),
          if (_enabled) _overlayCard(context),
          _appsCard(context),
          if (_days.isNotEmpty) ...[
            _todayCard(context),
            const SizedBox(height: 12),
            _weekCard(context),
            const SizedBox(height: 12),
            _historyCard(context),
          ],
          const SizedBox(height: 12),
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
    return Card(
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
              onPressed: () => _channel.invokeMethod('openSettings'),
              icon: const Icon(Icons.settings_accessibility),
              label: const Text('Open Accessibility settings'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _todayCard(BuildContext context) {
    final today = _days.first.value;
    final todaySecs = _seconds[_days.first.key] ?? {};
    final yesterday = _days.length > 1 ? _total(_days[1].value) : 0;
    final total = _total(today);
    // Apps with reels or time today, most reels first.
    final pkgs = {...today.keys, ...todaySecs.keys}.toList()
      ..sort((a, b) => (today[b] ?? 0).compareTo(today[a] ?? 0));
    final diff = total - yesterday;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Today', style: Theme.of(context).textTheme.titleMedium),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('$total',
                    style: Theme.of(context).textTheme.displayMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text('reels', style: Theme.of(context).textTheme.titleMedium),
                ),
              ],
            ),
            if (yesterday > 0 || total > 0)
              Text(
                diff == 0
                    ? 'Same as yesterday'
                    : '${diff.abs()} ${diff > 0 ? 'more' : 'fewer'} than yesterday ($yesterday)',
                style: TextStyle(color: diff > 0 ? Colors.red : Colors.green),
              ),
            if (todaySecs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('⏱ ${formatTime(_total(todaySecs))} in reel apps today'),
              ),
            const SizedBox(height: 16),
            if (pkgs.isEmpty)
              const Text('No reels scrolled yet today 🎉')
            else
              for (final p in pkgs)
                _appRow(context, _appName(p), today[p] ?? 0, total, todaySecs[p] ?? 0),
          ],
        ),
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
    final totals = week.map((e) => _total(e.value)).toList();
    final maxVal = totals.fold(1, (a, b) => b > a ? b : a);
    final avg = totals.isEmpty ? 0 : (totals.reduce((a, b) => a + b) / totals.length).round();
    const dayNames = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Last 7 days', style: Theme.of(context).textTheme.titleMedium)),
                Text('avg $avg / day', style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 150,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < week.length; i++)
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text('${totals[i]}', style: const TextStyle(fontSize: 11)),
                          const SizedBox(height: 4),
                          Container(
                            height: 110 * totals[i] / maxVal + 2,
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(
                              color: i == week.length - 1 ? scheme.primary : scheme.primary.withValues(alpha: 0.45),
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(dayNames[DateTime.parse(week[i].key).weekday - 1],
                              style: TextStyle(color: scheme.onSurfaceVariant)),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Daily report', style: Theme.of(context).textTheme.titleMedium),
            ),
            for (var i = 0; i < _days.length; i++)
              if (i < 2 || _total(_days[i].value) > 0)
                ListTile(
                  dense: true,
                  title: Text(_dayLabel(_days[i].key, i)),
                  subtitle: _days[i].value.isEmpty
                      ? null
                      : Text(
                          '${(_days[i].value.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).map((e) => '${_appName(e.key)} ${e.value}').join(' · ')}'
                          '${(_seconds[_days[i].key] ?? {}).isEmpty ? '' : '\n⏱ ${formatTime(_total(_seconds[_days[i].key]!))}'}',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                  trailing: Text('${_total(_days[i].value)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
