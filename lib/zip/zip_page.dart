import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'zip_service.dart';
import 'zip_viewer_screen.dart';

/// Zip tool home: make a zip (optionally locked), open / unzip one, and the zips made here.
class ZipPage extends StatefulWidget {
  const ZipPage({super.key});

  @override
  State<ZipPage> createState() => ZipPageState();
}

class ZipPageState extends State<ZipPage> {
  List<Map>? _recent;

  void refresh() => _loadRecent();

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    try {
      final r = await ZipService.channel.invokeListMethod<Map>('recent') ?? [];
      if (mounted) setState(() => _recent = r);
    } catch (_) {
      if (mounted) setState(() => _recent = []);
    }
  }

  // ---- Create ------------------------------------------------------------------------

  Future<void> _create() async {
    final files = await FilePicker.pickFiles(dialogTitle: 'Pick files to zip');
    if (files.isEmpty || !mounted) return;
    final first = files.first.name;
    final suggested = files.length == 1
        ? (first.contains('.') ? first.substring(0, first.lastIndexOf('.')) : first)
        : 'Files ${DateTime.now().toString().substring(0, 16).replaceAll(':', '-')}';
    final opts = await showModalBottomSheet<({String name, String? password})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _CreateSheet(files: files, suggestedName: suggested),
    );
    if (opts == null || !mounted) return;
    try {
      final r = await ZipService.withProgress(
        context,
        'Zipping ${files.length} file${files.length == 1 ? '' : 's'}…',
        () => ZipService.channel.invokeMapMethod<String, Object>('create', {
          'files': [for (final f in files) {'src': f.path ?? f.uri.toString(), 'name': f.name}],
          'name': opts.name,
          'password': opts.password,
        }),
      );
      if (!mounted || r == null) return;
      _loadRecent();
      final name = r['name'] as String;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${opts.password != null ? '🔒 ' : ''}Saved Downloads/AbhiUtility/Zips/$name'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Share',
          onPressed: () => ZipService.channel.invokeMethod('share', {'uri': r['uri'], 'name': name}),
        ),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not zip: ${ZipService.message(e)}')));
      }
    }
  }

  // ---- Open ---------------------------------------------------------------------------

  Future<void> _pickAndOpen() async {
    final f = await FilePicker.pickFile(dialogTitle: 'Pick a zip file');
    if (f == null || !mounted) return;
    await _open(f.path ?? f.uri.toString(), f.name, savedUri: null);
  }

  Future<void> _open(String src, String name, {String? savedUri}) async {
    try {
      final path = await ZipService.withProgress(context, 'Opening $name…',
          () async => (await ZipService.channel.invokeMethod<String>('localCopy', {'src': src}))!);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ZipViewerScreen(path: path, name: name, savedUri: savedUri)),
      );
      _loadRecent();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open: ${ZipService.message(e)}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final recent = _recent;
    return RefreshIndicator(
      onRefresh: _loadRecent,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: _BigButton(
                  icon: Icons.folder_zip,
                  title: 'Create zip',
                  subtitle: 'Pick files, add a password if you like',
                  color: Colors.indigo,
                  onTap: _create,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _BigButton(
                  icon: Icons.unarchive,
                  title: 'Open / unzip',
                  subtitle: 'View, extract, lock or unlock a zip',
                  color: Colors.teal,
                  onTap: _pickAndOpen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text('Your zips', style: Theme.of(context).textTheme.titleMedium),
          Text('Downloads/AbhiUtility/Zips', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          const SizedBox(height: 8),
          if (recent == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (recent.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Column(
                children: [
                  Icon(Icons.folder_zip_outlined, size: 56, color: scheme.onSurfaceVariant),
                  const SizedBox(height: 8),
                  Text('No zips yet', style: TextStyle(color: scheme.onSurfaceVariant)),
                ],
              ),
            )
          else
            for (final z in recent)
              Card(
                child: ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.folder_zip)),
                  title: Text(z['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${ZipService.formatSize((z['size'] as num).toInt())} · '
                      '${DateTime.fromMillisecondsSinceEpoch((z['time'] as num).toInt()).toString().substring(0, 16)}'),
                  onTap: () => _open(z['uri'] as String, z['name'] as String, savedUri: z['uri'] as String),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'share') {
                        ZipService.channel.invokeMethod('share', {'uri': z['uri'], 'name': z['name']});
                      } else if (v == 'delete') {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text('Delete ${z['name']}?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                            ],
                          ),
                        );
                        if (ok == true) {
                          await ZipService.channel.invokeMethod('delete', {'uri': z['uri']});
                          _loadRecent();
                        }
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.share), title: Text('Share'))),
                      PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete'))),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.icon, required this.title, required this.subtitle, required this.color, required this.onTap});

  final IconData icon;
  final String title, subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(backgroundColor: color.withValues(alpha: 0.15), child: Icon(icon, color: color)),
                const SizedBox(height: 12),
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
      );
}

/// Name + optional password for a new zip.
class _CreateSheet extends StatefulWidget {
  const _CreateSheet({required this.files, required this.suggestedName});

  final List<PlatformFile> files;
  final String suggestedName;

  @override
  State<_CreateSheet> createState() => _CreateSheetState();
}

class _CreateSheetState extends State<_CreateSheet> {
  late final _name = TextEditingController(text: widget.suggestedName);
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  bool _lock = false;
  bool _hide = true;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _pass, _pass2]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (_name.text.trim().isEmpty) return setState(() => _error = 'Enter a name');
    if (_lock) {
      if (_pass.text.length < 4) return setState(() => _error = 'Password: at least 4 characters');
      if (_pass.text != _pass2.text) return setState(() => _error = "The passwords don't match");
    }
    Navigator.pop(context, (name: _name.text.trim(), password: _lock ? _pass.text : null));
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.files.fold<int>(0, (s, f) => s + (f.lengthSync() ?? 0));
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Create zip', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('${widget.files.length} file${widget.files.length == 1 ? '' : 's'}'
                '${total > 0 ? ' · ${ZipService.formatSize(total)}' : ''}'),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final f in widget.files)
                    Text('• ${f.name}', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Zip name', suffixText: '.zip', border: OutlineInputBorder()),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.lock_outline),
              title: const Text('Lock with password'),
              subtitle: const Text('AES-256 encrypted'),
              value: _lock,
              onChanged: (v) => setState(() => _lock = v),
            ),
            if (_lock) ...[
              TextField(
                controller: _pass,
                obscureText: _hide,
                decoration: InputDecoration(
                  labelText: 'Password',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _hide = !_hide),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _pass2,
                obscureText: _hide,
                decoration: const InputDecoration(labelText: 'Type it again', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 4),
              Text("Don't forget it: a locked zip can't be opened without the password.",
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _submit,
              icon: Icon(_lock ? Icons.lock : Icons.folder_zip),
              label: Text(_lock ? 'Create locked zip' : 'Create zip'),
            ),
          ],
        ),
      ),
    );
  }
}
