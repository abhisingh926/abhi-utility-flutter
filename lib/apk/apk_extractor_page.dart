import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One installed app (native side: ApkExtractor.kt).
class ApkApp {
  ApkApp.fromMap(Map m)
      : pkg = m['pkg'] as String,
        label = m['label'] as String? ?? m['pkg'] as String,
        version = m['version'] as String? ?? '',
        size = (m['size'] as num?)?.toInt() ?? 0,
        split = m['split'] as bool? ?? false,
        system = m['system'] as bool? ?? false,
        updated = (m['updated'] as num?)?.toInt() ?? 0;

  final String pkg, label, version;
  final int size, updated;
  final bool split, system;
}

/// App icon, fetched from the native side the first time its row is built and
/// cached for the rest of the session (so the list itself opens instantly).
class _AppIcon extends StatelessWidget {
  const _AppIcon(this.pkg, {this.size = 44});

  final String pkg;
  final double size;

  static const _channel = MethodChannel('abhi_utility/apk');
  static final Map<String, Future<Uint8List?>> _cache = {};

  static Future<Uint8List?> _load(String pkg) =>
      _channel.invokeMethod<Uint8List>('icon', {'pkg': pkg}).catchError((_) => null);

  @override
  Widget build(BuildContext context) {
    final future = _cache.putIfAbsent(pkg, () => _load(pkg));
    return SizedBox.square(
      dimension: size,
      child: FutureBuilder<Uint8List?>(
        future: future,
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes != null) return Image.memory(bytes, width: size, height: size, gaplessPlayback: true);
          if (snap.connectionState != ConnectionState.done) return const SizedBox();
          return Icon(Icons.android, size: size);
        },
      ),
    );
  }
}

enum _Sort { name, size, recent }

/// Extract the APK of any installed app: share it to any app or save it to Downloads.
class ApkExtractorPage extends StatefulWidget {
  const ApkExtractorPage({super.key});

  @override
  State<ApkExtractorPage> createState() => ApkExtractorPageState();
}

class ApkExtractorPageState extends State<ApkExtractorPage> {
  static const _channel = MethodChannel('abhi_utility/apk');

  List<ApkApp>? _apps;
  String? _error;
  bool _system = false;
  _Sort _sort = _Sort.name;
  String _query = '';

  /// The page is only built when its tab is first opened (not at app start), so
  /// loading here is lazy. (refresh() alone missed that first visit: the tab calls it
  /// in the same frame the page is created, before this state exists, which left
  /// the spinner up until the tab was opened a second time.)
  @override
  void initState() {
    super.initState();
    _load();
  }

  void refresh() {
    if (_apps == null && !_loading) _load();
  }

  bool _loading = false;

  Future<void> _load() async {
    _loading = true;
    // Back to the spinner. Nothing to clear on the first load, which runs in
    // initState, where setState isn't allowed.
    if (_apps != null || _error != null) {
      setState(() {
        _apps = null;
        _error = null;
      });
    }
    try {
      final raw = await _channel.invokeListMethod<Map>('list', {'system': _system}) ?? [];
      if (mounted) setState(() => _apps = raw.map(ApkApp.fromMap).toList());
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message ?? 'Could not list apps');
    } finally {
      _loading = false;
    }
  }

  static String formatSize(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).ceil()} KB';
  }

  /// action: share | save | open
  Future<void> _export(ApkApp app, String action) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text('Extracting ${app.label} (${formatSize(app.size)})…')),
          ],
        ),
      ),
    );
    try {
      final r = await _channel.invokeMapMethod<String, Object>('export', {'pkg': app.pkg, 'action': action});
      navigator.pop();
      if (action == 'save') {
        final name = r?['name'] ?? '${app.label}.apk';
        messenger.showSnackBar(SnackBar(
          content: Text('Saved to Downloads/AbhiUtility/APKs/$name'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(label: 'Share', onPressed: () => _export(app, 'share')),
        ));
      }
    } on PlatformException catch (e) {
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('Could not extract ${app.label}: ${e.message}')));
    }
  }

  void _openSheet(ApkApp app) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: _AppIcon(app.pkg, size: 48),
              title: Text(app.label, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('${app.pkg}\n'
                  '${app.version.isEmpty ? '' : 'v${app.version} · '}${formatSize(app.size)}'),
              isThreeLine: true,
            ),
            if (app.split)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'This app comes in several parts, so it is saved as one .apks file. '
                  'To install it on another phone, open it with an app like "SAI" (Split APKs Installer).',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
                ),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('Share'),
              subtitle: const Text('WhatsApp, Telegram, Bluetooth, Quick Share, Drive…'),
              onTap: () {
                Navigator.pop(context);
                _export(app, 'share');
              },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Save to Downloads'),
              subtitle: const Text('Downloads/AbhiUtility/APKs'),
              onTap: () {
                Navigator.pop(context);
                _export(app, 'save');
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('App info'),
              onTap: () {
                Navigator.pop(context);
                _channel.invokeMethod('appInfo', {'pkg': app.pkg});
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final apps = _apps;
    final q = _query.trim().toLowerCase();
    final shown = apps == null
        ? <ApkApp>[]
        : (apps
            .where((a) => q.isEmpty || a.label.toLowerCase().contains(q) || a.pkg.toLowerCase().contains(q))
            .toList()
          ..sort(switch (_sort) {
            _Sort.name => (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
            _Sort.size => (a, b) => b.size.compareTo(a.size),
            _Sort.recent => (a, b) => b.updated.compareTo(a.updated),
          }));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Search apps',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (final (s, label) in [(_Sort.name, 'A–Z'), (_Sort.size, 'Biggest'), (_Sort.recent, 'Recently updated')])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: _sort == s,
                    onSelected: (_) => setState(() => _sort = s),
                  ),
                ),
              FilterChip(
                label: const Text('System apps'),
                selected: _system,
                onSelected: (on) {
                  _system = on;
                  _load();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: _error != null
              ? Center(child: Text(_error!))
              : apps == null
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: shown.length + 1,
                        itemBuilder: (context, i) {
                          if (i == 0) {
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                              child: Text('${shown.length} apps · tap one to share or save its APK',
                                  style: TextStyle(color: scheme.onSurfaceVariant)),
                            );
                          }
                          final a = shown[i - 1];
                          return ListTile(
                            leading: _AppIcon(a.pkg),
                            title: Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              '${a.version.isEmpty ? '' : 'v${a.version} · '}${formatSize(a.size)}'
                              '${a.split ? ' · .apks' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              tooltip: 'Share APK',
                              icon: const Icon(Icons.share),
                              onPressed: () => _export(a, 'share'),
                            ),
                            onTap: () => _openSheet(a),
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }
}
