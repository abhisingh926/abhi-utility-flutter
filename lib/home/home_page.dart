import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account/legal_links.dart';
import '../account/api_client.dart';
import '../app_theme.dart';
import '../account/profile_page.dart';
import '../account/subscription_page.dart';
import '../diary/diary_store.dart';
import 'app_share.dart';
import 'nav_prefs.dart';

/// Groups the features on the Home page, in this order.
enum FeatureCategory {
  documents('Documents'),
  productivity('Productivity'),
  security('Security & privacy'),
  device('Device tools');

  const FeatureCategory(this.label);
  final String label;
}

/// A feature shown on the home page.
class HomeFeature {
  const HomeFeature({
    required this.tab,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.category,
  });

  /// Bottom-bar tab index it opens.
  final int tab;
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final FeatureCategory category;
}

/// Home: greeting with today's numbers, account status, grouped tools, share.
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
    } on MissingPluginException {
      // Not on Android (e.g. tests): leave the stats empty.
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
        _snack('The bottom bar is full (${NavPrefs.maxPinned}). Unpin a tool first.');
        return;
      }
      pinned.add(f.tab);
      _snack('${f.title} added to the bottom bar');
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

  /// Long-press on a tool: what it does, open it, pin / unpin it.
  Future<void> _showFeature(HomeFeature f) async {
    HapticFeedback.selectionClick();
    final pinned = widget.pinned.contains(f.tab);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => _FeatureSheet(feature: f, pinned: pinned),
    );
    if (action == 'open') widget.onOpen(f.tab);
    if (action == 'pin') _togglePin(f);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 12) return 'Good morning';
    if (h >= 12 && h < 17) return 'Good afternoon';
    return 'Good evening';
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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          // ---- Greeting + today ----
          ValueListenableBuilder<AccountUser?>(
            valueListenable: ApiClient.instance.user,
            builder: (context, user, _) => _HeroCard(
              date: _date(),
              greeting: _greeting(),
              name: _firstName(user),
              reels: _StatData(
                icon: Icons.slow_motion_video,
                value: _reelsToday == null ? '—' : '$_reelsToday',
                label: _minutesToday == null ? 'Reels today' : 'Reels · $_minutesToday min',
                onTap: () => widget.onOpen(_tabOf(Icons.slow_motion_video)),
              ),
              tasks: _StatData(
                icon: Icons.task_alt,
                value: _tasksTotal == 0 ? '0' : '$_tasksDone/$_tasksTotal',
                label: _tasksTotal == 0 ? 'No tasks today' : 'Tasks done',
                progress: _tasksTotal == 0 ? null : _tasksDone / _tasksTotal,
                onTap: () => widget.onOpen(_tabOf(Icons.checklist)),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ---- Account ----
          const SubscriptionBanner(), // free trial / subscribe (Cloud backup is in My Profile)

          // ---- Tools ----
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 24, 0, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Tools',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2)),
                      const SizedBox(height: 2),
                      Text('Long-press a tool to pin it to the bottom bar',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: _editBar,
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Customize'),
                ),
              ],
            ),
          ),
          for (final category in FeatureCategory.values)
            if (widget.features.any((f) => f.category == category))
              _CategorySection(
                label: category.label,
                features: [for (final f in widget.features) if (f.category == category) f],
                pinned: widget.pinned,
                onTap: (f) => widget.onOpen(f.tab),
                onLongPress: _showFeature,
              ),

          // ---- Refer ----
          const SizedBox(height: 20),
          _Panel(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              leading: _IconBadge(icon: Icons.card_giftcard, color: scheme.primary),
              title: const Text('Refer & earn', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Invite friends with your code and get free months of Pro'),
              trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
              // Profile has the referral code and Invite button (logged out: login first).
              onTap: () => ProfilePage.open(context),
            ),
          ),
          if (_version.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Center(
                child: Text('Abhi Utility · Version $_version',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11, letterSpacing: 0.3)),
              ),
            ),
          Center(
            child: TextButton(
              onPressed: () => LegalLinks.open(context, LegalLinks.privacyUrl),
              child: const Text('Privacy policy', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  static String? _firstName(AccountUser? user) {
    final name = user?.name?.trim();
    if (name == null || name.isEmpty) return null;
    return name.split(RegExp(r'\s+')).first;
  }

  int _tabOf(IconData icon) => widget.features.firstWhere((f) => f.icon == icon).tab;
}

// ---- Building blocks -----------------------------------------------------------------

/// Flat surface with a hairline border: the base for every Home card.
class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: child,
    );
  }
}

/// Icon in a softly tinted rounded square.
class _IconBadge extends StatelessWidget {
  const _IconBadge({required this.icon, required this.color, this.size = 40});
  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(icon, color: color, size: size * 0.55),
    );
  }
}

class _StatData {
  const _StatData({required this.icon, required this.value, required this.label, required this.onTap, this.progress});
  final IconData icon;
  final String value;
  final String label;
  final double? progress;
  final VoidCallback onTap;
}

/// Brand-coloured header: date, greeting and today's two numbers.
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.date,
    required this.greeting,
    required this.name,
    required this.reels,
    required this.tasks,
  });

  final String date;
  final String greeting;
  final String? name;
  final _StatData reels;
  final _StatData tasks;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [BrandColors.navy, BrandColors.indigo],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            // Soft cyan glow, echoing the logo.
            Positioned(
              right: -60,
              top: -70,
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    BrandColors.cyan.withValues(alpha: 0.28),
                    BrandColors.cyan.withValues(alpha: 0),
                  ]),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(date.toUpperCase(),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                      )),
                  const SizedBox(height: 6),
                  Text(name == null ? greeting : '$greeting, $name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      )),
                  const SizedBox(height: 2),
                  Text("Here's your day at a glance",
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13)),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(child: _HeroStat(data: reels)),
                      const SizedBox(width: 10),
                      Expanded(child: _HeroStat(data: tasks)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.data});
  final _StatData data;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: data.onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(data.icon, size: 18, color: BrandColors.cyan),
                  const Spacer(),
                  Icon(Icons.arrow_outward, size: 14, color: Colors.white.withValues(alpha: 0.45)),
                ],
              ),
              const SizedBox(height: 10),
              Text(data.value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  )),
              const SizedBox(height: 2),
              Text(data.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12)),
              if (data.progress != null) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: data.progress,
                    minHeight: 4,
                    color: BrandColors.cyan,
                    backgroundColor: Colors.white.withValues(alpha: 0.15),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A category label and its tools in a 3-column grid.
class _CategorySection extends StatelessWidget {
  const _CategorySection({
    required this.label,
    required this.features,
    required this.pinned,
    required this.onTap,
    required this.onLongPress,
  });

  final String label;
  final List<HomeFeature> features;
  final List<int> pinned;
  final void Function(HomeFeature) onTap;
  final void Function(HomeFeature) onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
          child: Text(label.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
                color: scheme.onSurfaceVariant,
              )),
        ),
        _Panel(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.2,
              children: [
                for (final f in features)
                  _ToolTile(
                    feature: f,
                    pinned: pinned.contains(f.tab),
                    onTap: () => onTap(f),
                    onLongPress: () => onLongPress(f),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.feature, required this.pinned, required this.onTap, required this.onLongPress});
  final HomeFeature feature;
  final bool pinned;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      hint: feature.subtitle,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  _IconBadge(icon: feature.icon, color: feature.color, size: 50),
                  if (pinned)
                    Positioned(
                      right: -4,
                      top: -4,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.surfaceContainerLow, width: 2),
                        ),
                        child: Icon(Icons.push_pin, size: 10, color: scheme.onPrimary),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(feature.title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, height: 1.2)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Details for one tool, with Open and Pin / Unpin. Pops 'open' or 'pin'.
class _FeatureSheet extends StatelessWidget {
  const _FeatureSheet({required this.feature, required this.pinned});
  final HomeFeature feature;
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _IconBadge(icon: feature.icon, color: feature.color, size: 52),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(feature.title,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(feature.subtitle, style: TextStyle(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context, 'pin'),
                    icon: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined, size: 18),
                    label: Text(pinned ? 'Unpin from bar' : 'Pin to bar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, 'open'),
                    child: const Text('Open'),
                  ),
                ),
              ],
            ),
          ],
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
                Text('Customize bottom bar',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text('${_checked.length} / ${NavPrefs.maxPinned}',
                    style: TextStyle(color: full ? scheme.primary : scheme.onSurfaceVariant)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text('Home is always shown. Select tools to add them and drag to reorder.',
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
                        _IconBadge(icon: _order[i].icon, color: _order[i].color, size: 32),
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
