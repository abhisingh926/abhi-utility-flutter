import 'package:flutter/material.dart';

import 'pdf_store.dart';
import 'pdf_viewer_screen.dart';

/// PDF Viewer module: open any PDF from the phone or a recent one, then view,
/// search and edit it (PdfViewerScreen / PdfEditorScreen).
class PdfViewerHomePage extends StatefulWidget {
  const PdfViewerHomePage({super.key});

  @override
  State<PdfViewerHomePage> createState() => PdfViewerHomePageState();
}

class PdfViewerHomePageState extends State<PdfViewerHomePage> {
  List<RecentPdf> _recent = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  /// Reloads the recent list (files deleted from Downloads are dropped).
  Future<void> refresh() async {
    final list = await PdfStore.recents();
    if (mounted) {
      setState(() {
        _recent = list;
        _loading = false;
      });
    }
  }

  /// Opens a local PDF file in the viewer (also used for "Open with → Abhi Utility").
  Future<void> openInViewer(String path, String title, {String? savedUri}) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PdfViewerScreen(path: path, title: title, savedUri: savedUri),
    ));
    refresh(); // the editor may have saved new files
  }

  Future<void> _openFromPhone() async {
    try {
      final picked = await PdfStore.pickPdf();
      if (picked == null) return;
      await openInViewer(picked.path, picked.name);
    } catch (e) {
      _snack('Could not open PDF: $e');
    }
  }

  Future<void> _openRecent(RecentPdf pdf) async {
    try {
      final path = await PdfStore.localCopy(pdf.uri);
      await openInViewer(path, pdf.name, savedUri: pdf.uri);
    } catch (e) {
      _snack('Could not open PDF: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _date(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('PDF Viewer', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Open any PDF to read, search, draw, sign, add text, reorder or merge pages.',
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          Material(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _openFromPhone,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Icon(Icons.folder_open, size: 44, color: scheme.onPrimaryContainer),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Open a PDF',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold, color: scheme.onPrimaryContainer)),
                          Text('From Downloads, WhatsApp, Drive…',
                              style: TextStyle(color: scheme.onPrimaryContainer.withValues(alpha: 0.8))),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: scheme.onPrimaryContainer),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text('Tip: in any app, tap a PDF → Open with → Abhi Utility.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          const SizedBox(height: 24),
          Row(
            children: [
              Text('Recent PDFs', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              IconButton(tooltip: 'Refresh', onPressed: refresh, icon: const Icon(Icons.refresh)),
            ],
          ),
          if (_loading)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (_recent.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('PDFs you create or edit will appear here',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            )
          else
            for (final p in _recent)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.picture_as_pdf, color: Colors.red, size: 32),
                  title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${p.pages} page${p.pages == 1 ? '' : 's'} · ${_date(p.created)}'),
                  onTap: () => _openRecent(p),
                  trailing: IconButton(
                    tooltip: 'Share',
                    icon: const Icon(Icons.share),
                    onPressed: () => PdfStore.share(p.uri),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
