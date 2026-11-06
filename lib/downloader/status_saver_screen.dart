import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// WhatsApp Status Saver: shows the statuses you've viewed in WhatsApp and
/// saves them to the Gallery. Native side: StatusSaver.kt.
class StatusSaverScreen extends StatefulWidget {
  const StatusSaverScreen({super.key});

  @override
  State<StatusSaverScreen> createState() => _StatusSaverScreenState();
}

class _Status {
  _Status.fromMap(Map m)
      : uri = m['uri'] as String,
        name = m['name'] as String,
        mime = m['mime'] as String,
        modified = DateTime.fromMillisecondsSinceEpoch((m['modified'] as num).toInt());

  final String uri;
  final String name;
  final String mime;
  final DateTime modified;
  bool get isVideo => mime.startsWith('video/');
}

class _StatusSaverScreenState extends State<StatusSaverScreen> {
  static const _channel = MethodChannel('abhi_utility/status');

  bool _business = false;
  bool _loading = true;
  bool _hasAccess = false;
  List<_Status> _items = [];
  final Map<String, Future<Uint8List?>> _thumbs = {};
  final Set<String> _saved = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, Object> get _args => {'business': _business};

  Future<void> _load() async {
    setState(() => _loading = true);
    final access = await _channel.invokeMethod<bool>('hasAccess', _args) ?? false;
    var items = <_Status>[];
    if (access) {
      final raw = await _channel.invokeListMethod<Map>('list', _args);
      items = (raw ?? []).map(_Status.fromMap).toList();
    }
    if (!mounted) return;
    setState(() {
      _hasAccess = access;
      _items = items;
      _loading = false;
    });
  }

  Future<void> _allowAccess() async {
    final ok = await _channel.invokeMethod<bool>('pick', _args);
    if (ok == null) return; // cancelled
    if (!ok) {
      _snack('That is not the ".Statuses" folder. Tap "Use this folder" when the picker opens on .Statuses.');
    }
    await _load();
  }

  Future<void> _save(_Status s) async {
    try {
      final where = await _channel.invokeMethod<String>('save', {'uri': s.uri, 'name': s.name, 'mime': s.mime});
      setState(() => _saved.add(s.uri));
      _snack('Saved to $where — it is in your Gallery');
    } on PlatformException catch (e) {
      _snack('Could not save: ${e.message}');
    }
  }

  Future<void> _saveAll() async {
    final todo = _items.where((s) => !_saved.contains(s.uri)).toList();
    for (final s in todo) {
      try {
        await _channel.invokeMethod('save', {'uri': s.uri, 'name': s.name, 'mime': s.mime});
        _saved.add(s.uri);
      } catch (_) {}
    }
    setState(() {});
    _snack('Saved ${todo.length} statuses to your Gallery');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    return '${d.inHours} h ago';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp Status'),
        actions: [
          if (_hasAccess && _items.isNotEmpty)
            TextButton.icon(onPressed: _saveAll, icon: const Icon(Icons.download), label: const Text('Save all')),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('WhatsApp')),
                ButtonSegment(value: true, label: Text('WhatsApp Business')),
              ],
              selected: {_business},
              onSelectionChanged: (s) {
                setState(() => _business = s.first);
                _load();
              },
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : !_hasAccess
                    ? _accessHelp(scheme)
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: _items.isEmpty
                            ? ListView(
                                children: [
                                  const SizedBox(height: 80),
                                  const Icon(Icons.hourglass_empty, size: 56),
                                  const SizedBox(height: 12),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 32),
                                    child: Text(
                                      'No statuses yet.\nOpen WhatsApp → Updates and view a status: '
                                      'it appears here. Pull down to refresh.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: scheme.onSurfaceVariant),
                                    ),
                                  ),
                                ],
                              )
                            : GridView.builder(
                                padding: const EdgeInsets.all(8),
                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  mainAxisSpacing: 6,
                                  crossAxisSpacing: 6,
                                  childAspectRatio: 0.62,
                                ),
                                itemCount: _items.length,
                                itemBuilder: (context, i) => _tile(_items[i], scheme),
                              ),
                      ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              'Statuses are saved only on your phone. Ask before sharing other people\'s statuses.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _accessHelp(ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(Icons.folder_open, size: 64),
        const SizedBox(height: 12),
        Text('Allow access to WhatsApp statuses',
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Text(
          'WhatsApp keeps the statuses you view in a hidden folder. Android needs your OK once:\n\n'
          '1. Tap "Allow access" — a folder screen opens on ".Statuses".\n'
          '2. Tap "Use this folder", then "Allow".',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(onPressed: _allowAccess, icon: const Icon(Icons.lock_open), label: const Text('Allow access')),
        const SizedBox(height: 12),
        Text(
          'Tip: view the status in WhatsApp first, otherwise the folder may not exist yet.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _tile(_Status s, ColorScheme scheme) {
    final thumb = _thumbs.putIfAbsent(
      s.uri,
      () => _channel.invokeMethod<Uint8List>('thumb', {'uri': s.uri, 'video': s.isVideo}),
    );
    final saved = _saved.contains(s.uri);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onTap: () => _channel.invokeMethod('open', {'uri': s.uri, 'mime': s.mime}),
            child: FutureBuilder<Uint8List?>(
              future: thumb,
              builder: (context, snap) => snap.data == null
                  ? ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(s.isVideo ? Icons.movie : Icons.image, color: scheme.outline),
                    )
                  : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
            ),
          ),
          if (s.isVideo)
            const Center(child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 40)),
          Positioned(
            left: 6,
            bottom: 6,
            child: Text(_ago(s.modified),
                style: const TextStyle(color: Colors.white, fontSize: 11, shadows: [Shadow(blurRadius: 4)])),
          ),
          Positioned(
            right: 4,
            bottom: 4,
            child: IconButton.filled(
              tooltip: saved ? 'Saved' : 'Save',
              style: IconButton.styleFrom(backgroundColor: saved ? Colors.green : scheme.primary),
              iconSize: 20,
              onPressed: saved ? null : () => _save(s),
              icon: Icon(saved ? Icons.check : Icons.download, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
