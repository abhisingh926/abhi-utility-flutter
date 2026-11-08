import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'zip_service.dart';

class _Entry {
  _Entry(Map m)
      : name = (m['name'] as String).replaceAll('\\', '/'),
        dir = m['dir'] as bool? ?? false,
        size = (m['size'] as num?)?.toInt() ?? 0,
        compressed = (m['compressed'] as num?)?.toInt() ?? 0;

  final String name;
  final bool dir;
  final int size, compressed;
}

/// Shows what's inside a zip (with folders), previews images / text, extracts,
/// and adds, changes or removes the password.
class ZipViewerScreen extends StatefulWidget {
  const ZipViewerScreen({super.key, required this.path, required this.name, this.savedUri});

  /// Local copy of the zip.
  final String path;
  final String name;

  /// content:// uri when the zip is in Downloads/AbhiUtility/Zips (can be shared).
  final String? savedUri;

  @override
  State<ZipViewerScreen> createState() => _ZipViewerScreenState();
}

class _ZipViewerScreenState extends State<ZipViewerScreen> {
  static const _images = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'};
  static const _texts = {
    'txt', 'md', 'json', 'xml', 'csv', 'log', 'html', 'htm', 'css', 'js', 'ts', 'dart', 'kt', 'java',
    'py', 'yaml', 'yml', 'ini', 'cfg', 'conf', 'sh', 'bat', 'sql', 'properties', 'gradle', 'srt',
  };

  late String _path = widget.path;
  late String _name = widget.name;
  late String? _savedUri = widget.savedUri;

  List<_Entry>? _entries;
  bool _encrypted = false;
  String? _password; // set once the right password was entered
  String? _error;
  String _dir = ''; // current folder inside the zip, "" = top, else "a/b/"
  final Set<String> _selected = {};

  bool get _locked => _encrypted && _password == null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ZipService.channel.invokeMapMethod<String, Object>('list', {'path': _path});
      if (!mounted || r == null) return;
      setState(() {
        _encrypted = r['encrypted'] as bool? ?? false;
        _entries = [for (final m in r['entries'] as List) _Entry(m as Map)];
      });
      if (_locked) _unlock();
    } catch (e) {
      if (mounted) setState(() => _error = ZipService.message(e));
    }
  }

  Future<void> _unlock() async {
    String? error;
    while (mounted) {
      final pw = await ZipService.askPassword(context,
          title: 'This zip is locked', message: 'Enter the password to open $_name', error: error);
      if (pw == null || !mounted) return;
      try {
        final ok = await ZipService.withProgress(context, 'Checking password…',
            () async => await ZipService.channel.invokeMethod<bool>('checkPassword', {'path': _path, 'password': pw}) ?? false);
        if (ok) {
          if (mounted) setState(() => _password = pw);
          return;
        }
        error = 'Wrong password';
      } catch (e) {
        error = ZipService.message(e);
      }
    }
  }

  void _snack(String text, {SnackBarAction? action}) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(text), action: action, duration: const Duration(seconds: 5)));

  // ---- Folder view ------------------------------------------------------------------

  /// Sub-folders and files directly inside [_dir] (folders are also inferred from file paths).
  ({List<String> folders, List<_Entry> files}) _children() {
    final folders = <String>{};
    final files = <_Entry>[];
    for (final e in _entries ?? <_Entry>[]) {
      if (!e.name.startsWith(_dir)) continue;
      final rest = e.name.substring(_dir.length);
      if (rest.isEmpty) continue;
      final slash = rest.indexOf('/');
      if (slash >= 0) {
        folders.add(rest.substring(0, slash));
      } else if (!e.dir) {
        files.add(e);
      }
    }
    final sorted = folders.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return (folders: sorted, files: files);
  }

  List<String> _filesUnder(String prefix) =>
      [for (final e in _entries ?? <_Entry>[]) if (!e.dir && e.name.startsWith(prefix)) e.name];

  String _base(String name) => name.contains('/') ? name.substring(name.lastIndexOf('/') + 1) : name;

  String _ext(String name) => name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : '';

  IconData _iconFor(String name) {
    final x = _ext(name);
    if (_images.contains(x)) return Icons.image_outlined;
    if (_texts.contains(x)) return Icons.description_outlined;
    if (x == 'pdf') return Icons.picture_as_pdf_outlined;
    if (const {'mp4', 'mkv', 'mov', 'avi', 'webm', '3gp'}.contains(x)) return Icons.movie_outlined;
    if (const {'mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'}.contains(x)) return Icons.music_note_outlined;
    if (const {'zip', 'rar', '7z', 'apk', 'apks'}.contains(x)) return Icons.folder_zip_outlined;
    return Icons.insert_drive_file_outlined;
  }

  String get _folderName => _name.toLowerCase().endsWith('.zip') ? _name.substring(0, _name.length - 4) : _name;

  // ---- Actions -----------------------------------------------------------------------

  Future<void> _extract(List<String>? entries) async {
    if (_locked) return _unlock();
    final count = entries?.length ?? _filesUnder('').length;
    try {
      final r = await ZipService.withProgress(context, 'Extracting $count file${count == 1 ? '' : 's'}…',
          () => ZipService.channel.invokeMapMethod<String, Object>('extract', {
                'path': _path,
                'password': _password,
                'entries': entries,
                'folder': _folderName,
              }));
      if (!mounted || r == null) return;
      setState(_selected.clear);
      _snack('Extracted ${r['count']} file${r['count'] == 1 ? '' : 's'} to ${r['folder']}');
    } catch (e) {
      if (mounted) _snack(ZipService.isWrongPassword(e) ? 'Wrong password' : 'Could not extract: ${ZipService.message(e)}');
    }
  }

  Future<void> _openWith(_Entry e) async {
    if (_locked) return _unlock();
    try {
      final r = await ZipService.withProgress(context, 'Extracting ${_base(e.name)}…',
          () => ZipService.channel.invokeMapMethod<String, Object>('extract', {
                'path': _path,
                'password': _password,
                'entries': [e.name],
                'folder': _folderName,
              }));
      if (r == null || (r['uri'] as String).isEmpty) return;
      await ZipService.channel.invokeMethod('openWith', {'uri': r['uri'], 'name': _base(e.name)});
    } catch (err) {
      if (mounted) _snack('Could not open: ${ZipService.message(err)}');
    }
  }

  Future<void> _preview(_Entry e) async {
    if (_locked) return _unlock();
    final x = _ext(e.name);
    final isImage = _images.contains(x) && x != 'heic';
    final isText = _texts.contains(x);
    if (!isImage && !isText) return _openWith(e);
    try {
      final file = await ZipService.withProgress(context, 'Opening ${_base(e.name)}…',
          () async => (await ZipService.channel.invokeMethod<String>(
              'preview', {'path': _path, 'password': _password, 'entry': e.name}))!);
      if (!mounted) return;
      String? text;
      if (isText) {
        final bytes = await File(file).readAsBytes();
        text = const Utf8Decoder(allowMalformed: true).convert(bytes.take(300 * 1024).toList());
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(
              title: Text(_base(e.name)),
              actions: [
                IconButton(tooltip: 'Open with…', icon: const Icon(Icons.open_in_new), onPressed: () => _openWith(e)),
                IconButton(tooltip: 'Extract', icon: const Icon(Icons.download), onPressed: () => _extract([e.name])),
              ],
            ),
            body: isImage
                ? InteractiveViewer(maxScale: 8, child: Center(child: Image.file(File(file))))
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(text ?? '', style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                  ),
          ),
        ),
      );
    } catch (err) {
      if (mounted) _snack('Could not open: ${ZipService.message(err)}');
    }
  }

  /// Adds (newPassword), changes or removes (null) the lock. Saves to Downloads/AbhiUtility/Zips.
  Future<void> _relock(String? newPassword, String done) async {
    try {
      final r = await ZipService.withProgress(context, 'Saving $_name…',
          () => ZipService.channel.invokeMapMethod<String, Object>('relock', {
                'path': _path,
                'password': _password,
                'newPassword': newPassword,
                'name': _name,
              }));
      if (!mounted || r == null) return;
      setState(() {
        _path = r['path'] as String;
        _name = r['name'] as String;
        _savedUri = r['uri'] as String;
        _encrypted = newPassword != null;
        _password = newPassword;
      });
      _snack('$done · Downloads/AbhiUtility/Zips/$_name',
          action: SnackBarAction(label: 'Share', onPressed: _share));
    } catch (e) {
      if (mounted) _snack(ZipService.isWrongPassword(e) ? 'Wrong password' : 'Could not save: ${ZipService.message(e)}');
    }
  }

  Future<void> _addLock() async {
    final pw = await ZipService.askPassword(context,
        title: _encrypted ? 'New password' : 'Lock this zip',
        message: _encrypted ? null : 'Everything inside will be encrypted (AES-256).',
        confirm: true);
    if (pw == null || !mounted) return;
    await _relock(pw, _encrypted ? '🔒 Password changed' : '🔒 Zip locked');
  }

  Future<void> _removeLock() async {
    if (_locked) return _unlock();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove the password?'),
        content: const Text('Anyone with the file will be able to open it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) await _relock(null, '🔓 Password removed');
  }

  void _share() {
    final uri = _savedUri;
    if (uri != null) ZipService.channel.invokeMethod('share', {'uri': uri, 'name': _name});
  }

  // ---- UI ------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = _entries;
    final selecting = _selected.isNotEmpty;

    return PopScope(
      canPop: _dir.isEmpty && !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          if (selecting) {
            _selected.clear();
          } else {
            final parts = _dir.split('/')..removeWhere((p) => p.isEmpty);
            parts.removeLast();
            _dir = parts.isEmpty ? '' : '${parts.join('/')}/';
          }
        });
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(selecting ? '${_selected.length} selected' : _name, overflow: TextOverflow.ellipsis),
          actions: [
            if (selecting)
              IconButton(
                tooltip: 'Extract selected',
                icon: const Icon(Icons.download),
                onPressed: () => _extract(_selected.toList()),
              )
            else ...[
              if (_encrypted)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(_locked ? Icons.lock : Icons.lock_open, color: scheme.primary),
                ),
              if (_savedUri != null) IconButton(tooltip: 'Share zip', icon: const Icon(Icons.share), onPressed: _share),
              PopupMenuButton<String>(
                onSelected: (v) {
                  switch (v) {
                    case 'extract':
                      _extract(null);
                    case 'lock':
                      _locked ? _unlock() : _addLock();
                    case 'unlock':
                      _removeLock();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'extract', child: ListTile(leading: Icon(Icons.unarchive), title: Text('Extract all'))),
                  PopupMenuItem(
                    value: 'lock',
                    child: ListTile(
                      leading: const Icon(Icons.lock_outline),
                      title: Text(_encrypted ? 'Change password' : 'Add password lock'),
                    ),
                  ),
                  if (_encrypted)
                    const PopupMenuItem(value: 'unlock', child: ListTile(leading: Icon(Icons.lock_open), title: Text('Remove password'))),
                ],
              ),
            ],
          ],
        ),
        floatingActionButton: entries == null || _locked || selecting
            ? null
            : FloatingActionButton.extended(
                onPressed: () => _extract(null),
                icon: const Icon(Icons.unarchive),
                label: const Text('Unzip all'),
              ),
        body: _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
            : entries == null
                ? const Center(child: CircularProgressIndicator())
                : _locked
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.lock, size: 72, color: scheme.primary),
                            const SizedBox(height: 12),
                            const Text('This zip is password protected', style: TextStyle(fontSize: 16)),
                            const SizedBox(height: 16),
                            FilledButton.icon(onPressed: _unlock, icon: const Icon(Icons.key), label: const Text('Enter password')),
                          ],
                        ),
                      )
                    : _list(scheme),
      ),
    );
  }

  Widget _list(ColorScheme scheme) {
    final c = _children();
    final all = _filesUnder('');
    final total = (_entries ?? []).fold<int>(0, (s, e) => s + e.size);
    final zipped = (_entries ?? []).fold<int>(0, (s, e) => s + e.compressed);

    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '${all.length} files · ${ZipService.formatSize(total)}'
            '${zipped > 0 && total > 0 ? ' (zipped ${ZipService.formatSize(zipped)})' : ''}'
            '${_encrypted ? ' · 🔒 locked' : ''}',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
        if (_dir.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: Text('/$_dir', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: const Text('Back'),
            onTap: () => setState(() {
              final parts = _dir.split('/')..removeWhere((p) => p.isEmpty);
              parts.removeLast();
              _dir = parts.isEmpty ? '' : '${parts.join('/')}/';
            }),
          ),
        for (final f in c.folders)
          Builder(builder: (context) {
            final prefix = '$_dir$f/';
            final files = _filesUnder(prefix);
            final sel = files.isNotEmpty && files.every(_selected.contains);
            return ListTile(
              leading: Icon(Icons.folder, color: Colors.amber.shade700),
              title: Text(f),
              subtitle: Text('${files.length} files'),
              trailing: _selected.isEmpty ? const Icon(Icons.chevron_right) : Checkbox(value: sel, onChanged: (_) => _toggle(files, !sel)),
              selected: sel,
              onTap: () => _selected.isEmpty ? setState(() => _dir = prefix) : _toggle(files, !sel),
              onLongPress: () => _toggle(files, !sel),
            );
          }),
        for (final e in c.files)
          ListTile(
            leading: Icon(_iconFor(e.name)),
            title: Text(_base(e.name), maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(ZipService.formatSize(e.size)),
            selected: _selected.contains(e.name),
            trailing: _selected.isEmpty
                ? PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'open') _openWith(e);
                      if (v == 'extract') _extract([e.name]);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'open', child: ListTile(leading: Icon(Icons.open_in_new), title: Text('Open with…'))),
                      PopupMenuItem(value: 'extract', child: ListTile(leading: Icon(Icons.download), title: Text('Extract'))),
                    ],
                  )
                : Checkbox(value: _selected.contains(e.name), onChanged: (v) => _toggle([e.name], v ?? false)),
            onTap: () => _selected.isEmpty ? _preview(e) : _toggle([e.name], !_selected.contains(e.name)),
            onLongPress: () => _toggle([e.name], !_selected.contains(e.name)),
          ),
        if (c.folders.isEmpty && c.files.isEmpty)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('This zip is empty'))),
      ],
    );
  }

  void _toggle(List<String> names, bool on) => setState(() {
        if (on) {
          _selected.addAll(names);
        } else {
          _selected.removeAll(names);
        }
      });
}
