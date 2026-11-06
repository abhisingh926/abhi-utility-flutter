import 'package:flutter/material.dart';

import '../applock/pin_pad.dart';
import 'diary_lock.dart';
import 'journal_editor.dart';
import 'journal_store.dart';

/// Diary: list of entries (newest first) with photos, grouped by month.
class JournalPage extends StatefulWidget {
  const JournalPage({super.key});

  @override
  State<JournalPage> createState() => _JournalPageState();
}

class _JournalPageState extends State<JournalPage> with WidgetsBindingObserver {
  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  List<JournalEntry> _entries = [];
  bool _loading = true;
  String _query = '';
  bool _searching = false;

  /// Diary password lock.
  bool _lockEnabled = false;
  bool _unlocked = false;

  /// Fingerprint unlock.
  bool _bioAvailable = false;
  bool _bioEnabled = false;
  bool _bioPrompted = false; // prompt automatically once per lock

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DiaryLock.relock.addListener(_lockNow);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving the app (home button, another app, screen off) locks the diary.
    if (state == AppLifecycleState.paused && !DiaryLock.pickingPhoto) _lockNow();
  }

  void _lockNow() {
    _bioPrompted = false;
    if (_unlocked && mounted) setState(() => _unlocked = false);
  }

  Future<void> _unlockWithFingerprint() async {
    _bioPrompted = true;
    if (await DiaryLock.authenticate() && mounted) setState(() => _unlocked = true);
  }

  /// Offer fingerprint unlock (needs one successful scan to switch on).
  Future<void> _askEnableFingerprint() async {
    if (!_bioAvailable) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.fingerprint, size: 48),
        title: const Text('Unlock with fingerprint?'),
        content: const Text('Open your diary with your fingerprint. The password still works too.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Use fingerprint')),
        ],
      ),
    );
    if (yes != true) return;
    if (!await DiaryLock.authenticate()) {
      _snack('Fingerprint not confirmed — not turned on');
      return;
    }
    await DiaryLock.setBiometricEnabled(true);
    setState(() => _bioEnabled = true);
    _snack('👆 Fingerprint unlock on');
  }

  // ---- Lock settings --------------------------------------------------------------------

  Future<void> _lockMenu(String action) async {
    switch (action) {
      case 'set':
        final ok = await _passwordScreen(
          'Set diary password',
          _PinSetupBody(
            title: 'Create a diary password',
            onDone: (pin) async {
              await DiaryLock.setPin(pin);
              return null;
            },
          ),
        );
        if (ok) {
          setState(() {
            _lockEnabled = true;
            _unlocked = true;
          });
          _snack('🔒 Diary locked with a password');
          await _askEnableFingerprint();
        }
      case 'bio_on':
        await _askEnableFingerprint();
      case 'bio_off':
        await DiaryLock.setBiometricEnabled(false);
        setState(() => _bioEnabled = false);
        _snack('Fingerprint unlock off — password only');
      case 'lock':
        _lockNow();
      case 'change':
        final ok = await _passwordScreen(
          'Change diary password',
          _VerifyThen(
            next: _PinSetupBody(
              title: 'Choose a new password',
              onDone: (pin) async {
                await DiaryLock.setPin(pin);
                return null;
              },
            ),
          ),
        );
        if (ok) _snack('Diary password changed');
      case 'remove':
        final ok = await _passwordScreen(
          'Remove diary lock',
          _VerifyThen(onVerified: () async => DiaryLock.remove()),
        );
        if (ok) {
          setState(() {
            _lockEnabled = false;
            _bioEnabled = false;
          });
          _snack('Diary lock removed');
        }
    }
  }

  /// Shows a password flow on its own screen; true when it completed.
  Future<bool> _passwordScreen(String title, Widget body) async {
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => Scaffold(appBar: AppBar(title: Text(title)), body: body),
    ));
    return done ?? false;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DiaryLock.relock.removeListener(_lockNow);
    super.dispose();
  }

  Future<void> _load() async {
    final entries = await JournalStore.all();
    final locked = await DiaryLock.isEnabled();
    final bioAvailable = await DiaryLock.biometricAvailable();
    final bioEnabled = await DiaryLock.biometricEnabled();
    if (mounted) {
      setState(() {
        _entries = entries;
        _lockEnabled = locked;
        _bioAvailable = bioAvailable;
        _bioEnabled = bioEnabled && bioAvailable;
        _loading = false;
      });
    }
  }

  Future<void> _open([JournalEntry? entry]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => JournalEditor(entry: entry)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_lockEnabled && !_unlocked) {
      // Ask for the fingerprint straight away; the password pad stays as a fallback.
      if (_bioEnabled && !_bioPrompted) {
        _bioPrompted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _unlockWithFingerprint());
      }
      return Column(
        children: [
          Expanded(
            child: PinPad(
              title: '🔒 Your diary is locked',
              subtitle: _bioEnabled ? 'Use your fingerprint or the diary password' : 'Enter your diary password',
              onSubmit: (pin) async {
                if (!await DiaryLock.check(pin)) return 'Wrong password';
                setState(() => _unlocked = true);
                return null;
              },
            ),
          ),
          if (_bioEnabled)
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

    final scheme = Theme.of(context).colorScheme;
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty ? _entries : _entries.where((e) => e.text.toLowerCase().contains(q)).toList();

    // Group by month.
    final children = <Widget>[];
    String? lastMonth;
    for (final e in shown) {
      final month = '${_months[e.date.month - 1]} ${e.date.year}';
      if (month != lastMonth) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
          child: Text(month,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.primary)),
        ));
        lastMonth = month;
      }
      children.add(_EntryCard(
        entry: e,
        dateLabel: '${_days[e.date.weekday - 1]} ${e.date.day} · ${TimeOfDay.fromDateTime(e.date).format(context)}',
        onTap: () => _open(e),
      ));
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(),
        icon: const Icon(Icons.edit),
        label: const Text('Write'),
      ),
      body: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _searching
                          ? TextField(
                              autofocus: true,
                              decoration: const InputDecoration(
                                hintText: 'Search your diary',
                                prefixIcon: Icon(Icons.search),
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (v) => setState(() => _query = v),
                            )
                          : Text('${_entries.length} entr${_entries.length == 1 ? 'y' : 'ies'}',
                              style: TextStyle(color: scheme.onSurfaceVariant)),
                    ),
                    IconButton(
                      tooltip: _searching ? 'Close search' : 'Search',
                      icon: Icon(_searching ? Icons.close : Icons.search),
                      onPressed: () => setState(() {
                        _searching = !_searching;
                        _query = '';
                      }),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Diary lock',
                      icon: Icon(_lockEnabled ? Icons.lock : Icons.lock_open,
                          color: _lockEnabled ? scheme.primary : null),
                      onSelected: _lockMenu,
                      itemBuilder: (_) => _lockEnabled
                          ? [
                              const PopupMenuItem(value: 'lock', child: ListTile(leading: Icon(Icons.lock), title: Text('Lock now'))),
                              if (_bioAvailable)
                                _bioEnabled
                                    ? const PopupMenuItem(value: 'bio_off', child: ListTile(leading: Icon(Icons.fingerprint), title: Text('Turn off fingerprint')))
                                    : const PopupMenuItem(value: 'bio_on', child: ListTile(leading: Icon(Icons.fingerprint), title: Text('Unlock with fingerprint'))),
                              const PopupMenuItem(value: 'change', child: ListTile(leading: Icon(Icons.password), title: Text('Change password'))),
                              const PopupMenuItem(value: 'remove', child: ListTile(leading: Icon(Icons.lock_open), title: Text('Remove lock'))),
                            ]
                          : const [
                              PopupMenuItem(value: 'set', child: ListTile(leading: Icon(Icons.lock), title: Text('Lock diary with password'))),
                            ],
                    ),
                  ],
                ),
                if (_entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 64),
                    child: Column(
                      children: [
                        const Text('📔', style: TextStyle(fontSize: 56)),
                        const SizedBox(height: 12),
                        Text('Your diary is empty', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 6),
                        Text('Tap "Write" to add today\'s thoughts and photos.',
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  )
                else if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: Text('No entries contain "$_query"')),
                  ),
                ...children,
              ],
            ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry, required this.dateLabel, required this.onTap});
  final JournalEntry entry;
  final String dateLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const maxThumbs = 3;
    final extra = entry.images.length - maxThumbs;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(dateLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (entry.mood != null) Text(entry.mood!, style: const TextStyle(fontSize: 22)),
                ],
              ),
              if (entry.text.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(entry.text.trim(), maxLines: 3, overflow: TextOverflow.ellipsis),
              ],
              if (entry.images.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    for (var i = 0; i < entry.images.length && i < maxThumbs; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 76,
                            height: 76,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                JournalImage(name: entry.images[i], cacheWidth: 240),
                                if (i == maxThumbs - 1 && extra > 0)
                                  ColoredBox(
                                    color: Colors.black54,
                                    child: Center(
                                      child: Text('+$extra',
                                          style: const TextStyle(
                                              color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if (entry.text.trim().isEmpty && entry.images.isEmpty)
                Text('(only mood)', style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Create a password (twice), then close the screen with `true`.
class _PinSetupBody extends StatelessWidget {
  const _PinSetupBody({required this.title, required this.onDone});
  final String title;
  final Future<String?> Function(String pin) onDone;

  @override
  Widget build(BuildContext context) {
    return PinSetup(
      title: title,
      onDone: (pin) async {
        final error = await onDone(pin);
        if (error == null && context.mounted) Navigator.pop(context, true);
        return error;
      },
    );
  }
}

/// Ask for the current diary password first; then show [next] or run [onVerified].
class _VerifyThen extends StatefulWidget {
  const _VerifyThen({this.next, this.onVerified});
  final Widget? next;
  final Future<void> Function()? onVerified;

  @override
  State<_VerifyThen> createState() => _VerifyThenState();
}

class _VerifyThenState extends State<_VerifyThen> {
  bool _verified = false;

  @override
  Widget build(BuildContext context) {
    if (_verified && widget.next != null) return widget.next!;
    return PinPad(
      title: 'Enter your current diary password',
      onSubmit: (pin) async {
        if (!await DiaryLock.check(pin)) return 'Wrong password';
        if (widget.onVerified != null) {
          await widget.onVerified!();
          if (context.mounted) Navigator.pop(context, true);
        } else {
          setState(() => _verified = true);
        }
        return null;
      },
    );
  }
}
