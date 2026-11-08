import 'package:flutter/material.dart';

import 'sheet_store.dart';
import 'sheet_viewer.dart';

/// Excel viewer tab: open a file, recently opened files, and every Excel / CSV
/// file on the phone (after "All files access" is allowed).
class ExcelPage extends StatefulWidget {
  const ExcelPage({super.key});

  @override
  State<ExcelPage> createState() => ExcelPageState();
}

class ExcelPageState extends State<ExcelPage> with WidgetsBindingObserver {
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
    final recent = await SheetStore.recents();
    final access = await SheetStore.hasAllFilesAccess();
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
      final all = await SheetStore.scan();
      if (mounted) setState(() => _all = all);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not list files: $e')));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _pick() async {
    final f = await SheetStore.pick();
    if (f != null && mounted) await _open(f);
  }

  Future<void> _open(SheetFile f) async {
    await SheetViewer.open(context, f);
    final recent = await SheetStore.recents();
    if (mounted) setState(() => _recent = recent);
  }

  /// Opened with "Open with → Abhi Utility" (content uri, not remembered: the access is temporary).
  Future<void> openIncoming(String uri) async {
    final name = await SheetStore.nameOf(uri);
    if (!mounted) return;
    await SheetViewer.open(context, SheetFile(name: name, source: uri), remember: false);
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
          FilledButton.icon(
            onPressed: _pick,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: const Icon(Icons.folder_open),
            label: const Text('Open Excel file'),
          ),
          const SizedBox(height: 6),
          Text('Excel (.xlsx, .xlsm) and CSV files. Tip: "Open with → Abhi Utility" works too.',
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
                onTap: () => _open(f),
                onRemove: () async {
                  await SheetStore.removeRecent(f);
                  refresh();
                },
              ),
          ],

          _heading(context, all == null ? 'All Excel files on this phone' : 'All Excel files on this phone (${all.length})',
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
                      Expanded(child: Text('Find every Excel file', style: t.titleMedium)),
                    ]),
                    const SizedBox(height: 8),
                    const Text(
                      'To list all Excel and CSV files on your phone (Downloads, WhatsApp, Documents…), '
                      'Android needs you to allow "All files access" for Abhi Utility. '
                      'Files are only read on this phone, never uploaded.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      onPressed: SheetStore.requestAllFilesAccess,
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
              child: Text(_query.isEmpty ? 'No Excel or CSV files found on this phone.' : 'No files match "$_query".',
                  textAlign: TextAlign.center),
            )
          else
            for (final f in all) _FileTile(file: f, onTap: () => _open(f)),
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
  const _FileTile({required this.file, required this.onTap, this.onRemove});
  final SheetFile file;
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
    final (color, label) = switch (file.extension) {
      'csv' => (Colors.blue, 'CSV'),
      'xls' => (Colors.blueGrey, 'XLS'),
      _ => (Colors.green.shade700, 'XLSX'),
    };
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
