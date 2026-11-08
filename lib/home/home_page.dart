import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account/backup_button.dart';
import '../account/subscription_page.dart';
import '../diary/diary_store.dart';
import 'app_share.dart';
import 'nav_prefs.dart';

/// A feature shown on the home page.
class HomeFeature {
  const HomeFeature({
    required this.tab,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
  });

  /// Bottom-bar tab index it opens.
  final int tab;
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
}

/// Home: greeting, today's stats, all features, share the app.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.features,
    required this.onOpen,
    required this.pinned,
    required this.onPinnedChanged,
  });

  final List<HomeFeature> features;
  final void Function(int tab) onOpen;

  /// Tabs shown in the bottom bar (after Home), in order.
  final List<int> pinned;
  final void Function(List<int> pinned) onPinnedChanged;

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  static const _reels = MethodChannel('abhi_utility/reels');

  int? _reelsToday;
  int? _minutesToday;
  int _tasksDone = 0;
  int _tasksTotal = 0;
  String _version = '';

  @override
  void initState() {
    super.initState();
    refresh();
  }

  /// Reloads today's numbers (called when the Home tab is shown).
  Future<void> refresh() async {
    try {
      final counts = await _reels.invokeMapMethod<String, dynamic>('stats', {'days': 1}) ?? {};
      final times = await _reels.invokeMapMethod<String, dynamic>('timeStats', {'days': 1}) ?? {};
      int sum(Map<String, dynamic> m) => m.values
          .whereType<Map>()
          .expand((day) => day.values)
          .fold(0, (a, b) => a + (b as int));
      _reelsToday = sum(counts);
      _minutesToday = sum(times) ~/ 60;
    } on PlatformException {
      // Reel counter unavailable: leave the stats empty.
    }
    final today = await DiaryStore.load(DateTime.now());
    final info = await AppShare.info();
    if (!mounted) return;
    setState(() {
      _tasksDone = today.doneCount;
      _tasksTotal = today.tasks.length;
      _version = info.version;
    });
  }

  // ---- Bottom bar customisation ------------------------------------------------------

  void _togglePin(HomeFeature f) {
    final pinned = List.of(widget.pinned);
    if (pinned.contains(f.tab)) {
      pinned.remove(f.tab);
      _snack('${f.title} removed from the bottom bar');
    } else {
      if (pinned.length >= NavPrefs.maxPinned) {
        _snack('The bottom bar is full (${NavPrefs.maxPinned}). Unpin a feature first.');
        return;
      }
      pinned.add(f.tab);
      _snack('📌 ${f.title} added to the bottom bar');
    }
    widget.onPinnedChanged(pinned);
  }

  Future<void> _editBar() async {
    final result = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EditBarSheet(features: widget.features, pinned: widget.pinned),
    );
    if (result != null) widget.onPinnedChanged(result);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 5) return 'Good night 🌙';
    if (h < 12) return 'Good morning ☀️';
    if (h < 17) return 'Good afternoon 🌤️';
    if (h < 21) return 'Good evening 🌆';
    return 'Good night 🌙';
  }

  String _date() {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
      'September', 'October', 'November', 'December'];
    final d = DateTime.now();
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // ---- Greeting ----
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                colors: [Color(0xFF0B1A6B), Color(0xFF3A1C9C), Color(0xFF00A3D9)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.asset('static/image/icon/logo_256.png', width: 64, height: 64),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_greeting(),
                          style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(_date(), style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ---- Today ----
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  icon: Icons.slow_motion_video,
                  color: Colors.pink,
                  value: _reelsToday == null ? '–' : '$_reelsToday',
                  label: _minutesToday == null ? 'reels today' : 'reels · $_minutesToday min today',
                  onTap: () => widget.onOpen(_tabOf(Icons.slow_motion_video)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  icon: Icons.checklist,
                  color: Colors.green,
                  value: _tasksTotal == 0 ? '0' : '$_tasksDone/$_tasksTotal',
                  label: _tasksTotal == 0 ? 'tasks today' : 'tasks done today',
                  onTap: () => widget.onOpen(_tabOf(Icons.checklist)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const SubscriptionBanner(), // free trial / subscribe
          const BackupCard(),

          // ---- Features ----
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 0, 0),
            child: Row(
              children: [
                Text('All features', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  onPressed: _editBar,
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Edit bottom bar'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text('Tap 📌 on a feature to add it to the bottom bar (up to ${NavPrefs.maxPinned}).',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.05,
            children: [
              for (final f in _pinnedFirst())
                _FeatureCard(
                  feature: f,
                  pinned: widget.pinned.contains(f.tab),
                  onTap: () => widget.onOpen(f.tab),
                  onPin: () => _togglePin(f),
                ),
            ],
          ),

          // ---- Share ----
          const SizedBox(height: 16),
          Card(
            color: scheme.primaryContainer,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: CircleAvatar(
                backgroundColor: scheme.primary,
                child: Icon(Icons.share, color: scheme.onPrimary),
              ),
              title: const Text('Share Abhi Utility', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Send the app to friends via WhatsApp, Bluetooth, Quick Share…'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => AppShare.shareApk(context),
            ),
          ),
          if (_version.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Center(
                child: Text('Abhi Utility v$_version',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }

  int _tabOf(IconData icon) => widget.features.firstWhere((f) => f.icon == icon).tab;

  /// Features pinned to the bottom bar first (in bar order), then the rest.
  List<HomeFeature> _pinnedFirst() => [
        for (final t in widget.pinned) ...widget.features.where((f) => f.tab == t),
        ...widget.features.where((f) => !widget.pinned.contains(f.tab)),
      ];
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String value;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    Text(label,
                        maxLines: 2,
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.feature, required this.pinned, required this.onTap, required this.onPin});
  final HomeFeature feature;
  final bool pinned;
  final VoidCallback onTap;
  final VoidCallback onPin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: feature.color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(feature.icon, color: feature.color, size: 28),
                  ),
                  const Spacer(),
                  // Pin to / unpin from the bottom bar.
                  IconButton(
                    tooltip: pinned ? 'Remove from bottom bar' : 'Add to bottom bar',
                    visualDensity: VisualDensity.compact,
                    onPressed: onPin,
                    icon: Icon(
                      pinned ? Icons.push_pin : Icons.push_pin_outlined,
                      size: 20,
                      color: pinned ? scheme.primary : scheme.outline,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(feature.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 2),
              Text(feature.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Choose (tick, max [NavPrefs.maxPinned]) and order (drag) the bottom-bar features.
class _EditBarSheet extends StatefulWidget {
  const _EditBarSheet({required this.features, required this.pinned});
  final List<HomeFeature> features;
  final List<int> pinned;

  @override
  State<_EditBarSheet> createState() => _EditBarSheetState();
}

class _EditBarSheetState extends State<_EditBarSheet> {
  // Pinned features first (in bar order), then the rest.
  late final List<HomeFeature> _order = [
    for (final t in widget.pinned) widget.features.firstWhere((f) => f.tab == t),
    ...widget.features.where((f) => !widget.pinned.contains(f.tab)),
  ];
  late final Set<int> _checked = widget.pinned.toSet();

  List<int> get _result => [for (final f in _order) if (_checked.contains(f.tab)) f.tab];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final full = _checked.length >= NavPrefs.maxPinned;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Row(
              children: [
                Text('Bottom bar', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                Text('${_checked.length} / ${NavPrefs.maxPinned}',
                    style: TextStyle(color: full ? scheme.primary : scheme.onSurfaceVariant)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text('🏠 Home is always there. Tick features to add them, drag ☰ to change the order.',
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
          Flexible(
            child: ReorderableListView(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              onReorderItem: (from, to) => setState(() => _order.insert(to, _order.removeAt(from))),
              children: [
                for (var i = 0; i < _order.length; i++)
                  ListTile(
                    key: ValueKey(_order[i].tab),
                    leading: Checkbox(
                      value: _checked.contains(_order[i].tab),
                      // Can't tick more than the bar holds.
                      onChanged: !_checked.contains(_order[i].tab) && full
                          ? null
                          : (v) => setState(() => v == true
                              ? _checked.add(_order[i].tab)
                              : _checked.remove(_order[i].tab)),
                    ),
                    title: Row(
                      children: [
                        Icon(_order[i].icon, color: _order[i].color),
                        const SizedBox(width: 12),
                        Text(_order[i].title),
                      ],
                    ),
                    trailing: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, _result),
                child: const Text('Save'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
