import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../docs/doc_viewer.dart';
import '../docs/doc_writer.dart';
import 'sheet_store.dart';
import 'sheet_viewer.dart';
import 'sheet_writer.dart';

/// What a file tab (Excel viewer, Docs) shows and does.
class FileTabKind {
  const FileTabKind({
    required this.store,
    required this.newLabel,
    required this.newExtension,
    required this.newDefaultName,
    required this.newFile,
    required this.open,
    required this.hint,
    required this.typeName,
    required this.badge,
  });

  final FileStore store;
  final String newLabel; // "New spreadsheet"
  final String newExtension; // "xlsx"
  final String newDefaultName; // "Spreadsheet"
  final Uint8List Function() newFile;
  final Future<void> Function(BuildContext context, SheetFile file, {bool remember, bool edit}) open;
  final String hint;
  final String typeName; // "Excel" → "All Excel files on this phone"
  final (Color, String) Function(String extension) badge;
}

final excelKind = FileTabKind(
  store: sheetStore,
  newLabel: 'New spreadsheet',
  newExtension: 'xlsx',
  newDefaultName: 'Spreadsheet',
  newFile: newWorkbook,
  open: SheetViewer.open,
  hint: 'View and edit Excel (.xlsx, .xlsm) and CSV files. "Open with → Abhi Utility" works too.',
  typeName: 'Excel',
  badge: (ext) => switch (ext) {
    'csv' => (Colors.blue, 'CSV'),
    'xls' => (Colors.blueGrey, 'XLS'),
    _ => (Colors.green.shade700, 'XLSX'),
  },
);

final docsKind = FileTabKind(
  store: docStore,
  newLabel: 'New document',
  newExtension: 'docx',
  newDefaultName: 'Document',
  newFile: newDocument,
  open: DocViewer.open,
  hint: 'View and edit Word documents (.docx) and text files. "Open with → Abhi Utility" works too.',
  typeName: 'Word',
  badge: (ext) => switch (ext) {
    'txt' => (Colors.grey.shade700, 'TXT'),
    'doc' => (Colors.blueGrey, 'DOC'),
    _ => (const Color(0xFF2B579A), 'DOCX'),
  },
);

/// A file tab: open a file, create one, recently opened files, and every file of
/// this kind on the phone (after "All files access" is allowed).
class FileTabPage extends StatefulWidget {
  const FileTabPage({super.key, required this.kind});
  final FileTabKind kind;

  @override
  State<FileTabPage> createState() => FileTabPageState();
}

class FileTabPageState extends State<FileTabPage> with WidgetsBindingObserver {
  FileTabKind get _k => widget.kind;
  FileStore get _store => widget.kind.store;

  List<SheetFile> _recent = const [];
  List<SheetFile>? _all; // null = not loaded yet
  bool _access = false;
  bool _scanning = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from the "All files access" settings page: list the files.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh() async {
    final recent = await _store.recents();
    final access = await _store.hasAllFilesAccess();
    if (!mounted) return;
    setState(() {
      _recent = recent;
      _access = access;
    });
    if (access) await _scan();
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final all = await _store.scan();
      if (mounted) setState(() => _all = all);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not list files: $e')));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _pick() async {
    final f = await _store.pick();
    if (f != null && mounted) await _open(f);
  }

  /// Empty .xlsx in Downloads/AbhiUtility, opened ready to type.
  Future<void> _createNew() async {
    final now = DateTime.now();
    final ctl = TextEditingController(
        text: '${_k.newDefaultName} ${now.day.toString().padLeft(2, '0')}-${now.month.toString().padLeft(2, '0')}-${now.year}');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_k.newLabel),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(labelText: 'File name', suffixText: '.${_k.newExtension}'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctl.text), child: const Text('Create')),
        ],
      ),
    );
    final clean = name?.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (clean == null || clean.isEmpty || !mounted) return;
    try {
      final ext = '.${_k.newExtension}';
      final file = await _store.saveCopy(_k.newFile(), clean.toLowerCase().endsWith(ext) ? clean : '$clean$ext');
      if (!mounted) return;
      await _k.open(context, file, edit: true);
      refresh();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create the file: $e')));
    }
  }

  Future<void> _open(SheetFile f) async {
    await _k.open(context, f);
    final recent = await _store.recents();
    if (mounted) setState(() => _recent = recent);
  }

  /// Opened with "Open with → Abhi Utility" (content uri, not remembered: the access is temporary).
  Future<void> openIncoming(String uri) async {
    final name = await _store.nameOf(uri);
    if (!mounted) return;
    await _k.open(context, SheetFile(name: name, source: uri), remember: false);
  }

  bool _matches(SheetFile f) => _query.isEmpty || f.name.toLowerCase().contains(_query.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final recent = _recent.where(_matches).toList();
    final all = _all?.where(_matches).toList();

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _pick,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Open file'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _createNew,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  icon: const Icon(Icons.add),
                  label: Text(_k.newLabel),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(_k.hint,
              textAlign: TextAlign.center, style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          if (_recent.isNotEmpty || (_all?.isNotEmpty ?? false))
            TextField(
              decoration: const InputDecoration(
                hintText: 'Search files by name',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (q) => setState(() => _query = q.trim()),
            ),

          if (recent.isNotEmpty) ...[
            _heading(context, 'Recent'),
            for (final f in recent.take(_query.isEmpty ? 5 : 15))
              _FileTile(
                file: f,
                badge: _k.badge(f.extension),
                onTap: () => _open(f),
                onRemove: () async {
                  await _store.removeRecent(f);
                  refresh();
                },
              ),
          ],

          _heading(context, 'All ${_k.typeName} files on this phone${all == null ? '' : ' (${all.length})'}',
              trailing: _access
                  ? IconButton(
                      tooltip: 'Refresh',
                      onPressed: _scanning ? null : _scan,
                      icon: _scanning
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh),
                    )
                  : null),
          if (!_access)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.find_in_page_outlined, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Find every ${_k.typeName} file', style: t.titleMedium)),
                    ]),
                    const SizedBox(height: 8),
                    Text(
                      'To list all ${_k.typeName} files on your phone (Downloads, WhatsApp, Documents…), '
                      'Android needs you to allow "All files access" for Abhi Utility. '
                      'Files are only read on this phone, never uploaded.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      onPressed: _store.requestAllFilesAccess,
                      icon: const Icon(Icons.lock_open),
                      label: const Text('Allow access'),
                    ),
                  ],
                ),
              ),
            )
          else if (all == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (all.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_query.isEmpty ? 'No ${_k.typeName} files found on this phone.' : 'No files match "$_query".',
                  textAlign: TextAlign.center),
            )
          else
            for (final f in all) _FileTile(file: f, badge: _k.badge(f.extension), onTap: () => _open(f)),
        ],
      ),
    );
  }

  Widget _heading(BuildContext context, String text, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 0, 4),
        child: Row(
          children: [
            Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
            ?trailing,
          ],
        ),
      );
}

class _FileTile extends StatelessWidget {
  const _FileTile({required this.file, required this.badge, required this.onTap, this.onRemove});
  final SheetFile file;
  final (Color, String) badge;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  static String _size(int b) => b < 1024
      ? '$b B'
      : b < 1024 * 1024
          ? '${(b / 1024).toStringAsFixed(0)} KB'
          : '${(b / 1024 / 1024).toStringAsFixed(1)} MB';

  static String _date(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final (color, label) = badge;
    final details = [
      ?file.folder,
      if (file.size != null) _size(file.size!),
      if (file.modified != null) _date(file.modified!),
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
          child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
        ),
        title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: details.isEmpty ? null : Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: onRemove == null
            ? const Icon(Icons.chevron_right)
            : IconButton(tooltip: 'Remove from recent', icon: const Icon(Icons.close), onPressed: onRemove),
        onTap: onTap,
      ),
    );
  }
}
