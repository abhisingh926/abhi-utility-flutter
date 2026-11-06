import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'pdf_editor.dart';
import 'pdf_store.dart';

/// PDF viewer: scroll, pinch-zoom, search, go to page; opens the editor.
class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({super.key, required this.path, required this.title, this.savedUri});

  /// Local file path of the PDF.
  final String path;
  final String title;

  /// Downloads entry, if this file is saved there (used for Share / Open with).
  final String? savedUri;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  late String _path = widget.path;
  late String _title = widget.title;
  late String? _savedUri = widget.savedUri;

  final _controller = PdfViewerController();
  late final PdfTextSearcher _searcher = PdfTextSearcher(_controller)..addListener(_onSearch);
  final _searchField = TextEditingController();
  bool _searching = false;
  int? _page;
  int _pageCount = 0;

  void _onSearch() {
    if (mounted) setState(() {});
  }

  Future<void> _goToPageDialog() async {
    final controller = TextEditingController();
    final target = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Go to page'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: 'Page (1–$_pageCount)', border: const OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, int.tryParse(controller.text)), child: const Text('Go')),
        ],
      ),
    );
    if (target == null || _pageCount == 0) return;
    await _controller.goToPage(pageNumber: target.clamp(1, _pageCount));
  }

  Future<void> _edit() async {
    final result = await Navigator.of(context).push<EditorResult>(
      MaterialPageRoute(builder: (_) => PdfEditorScreen(path: _path, title: _title)),
    );
    if (result == null || !mounted) return;
    // Show the edited copy.
    setState(() {
      _path = result.path;
      _title = result.saved.name;
      _savedUri = result.saved.uri;
      _searching = false;
      _searcher.resetTextSearch();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved "${result.saved.name}" in Downloads/AbhiUtility')),
    );
  }

  /// Share / open in another app need the file in Downloads; save a copy first if needed.
  Future<String?> _ensureSaved() async {
    if (_savedUri != null) return _savedUri;
    try {
      final saved = await PdfStore.save(await File(_path).readAsBytes(), _title, _pageCount);
      setState(() => _savedUri = saved.uri);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved a copy in Downloads/AbhiUtility')),
        );
      }
      return saved.uri;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
      return null;
    }
  }

  Future<void> _menu(String action) async {
    switch (action) {
      case 'goto':
        await _goToPageDialog();
      case 'share':
        final uri = await _ensureSaved();
        if (uri != null) await PdfStore.share(uri);
      case 'save':
        await _ensureSaved();
      case 'external':
        final uri = await _ensureSaved();
        if (uri != null) await PdfStore.openExternally(uri);
    }
  }

  PreferredSizeWidget? _searchBar() {
    if (!_searching) return null;
    final count = _searcher.matches.length;
    final index = _searcher.currentIndex;
    return PreferredSize(
      preferredSize: const Size.fromHeight(56),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchField,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search in PDF',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.search),
                  suffixText: _searcher.isSearching
                      ? 'Searching…'
                      : _searchField.text.isEmpty
                          ? null
                          : count == 0
                              ? 'No matches'
                              : '${(index ?? 0) + 1} / $count',
                ),
                onChanged: (v) => v.trim().isEmpty
                    ? _searcher.resetTextSearch()
                    : _searcher.startTextSearch(v.trim(), caseInsensitive: true),
              ),
            ),
            IconButton(
              tooltip: 'Previous',
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: count == 0 ? null : () => _searcher.goToPrevMatch(),
            ),
            IconButton(
              tooltip: 'Next',
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: count == 0 ? null : () => _searcher.goToNextMatch(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
        bottom: _searchBar(),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: Icon(_searching ? Icons.search_off : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) {
                _searchField.clear();
                _searcher.resetTextSearch();
              }
            }),
          ),
          IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_document), onPressed: _edit),
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'goto', child: ListTile(leading: Icon(Icons.find_in_page), title: Text('Go to page'))),
              PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.share), title: Text('Share'))),
              PopupMenuItem(value: 'save', child: ListTile(leading: Icon(Icons.download), title: Text('Save to Downloads'))),
              PopupMenuItem(value: 'external', child: ListTile(leading: Icon(Icons.open_in_new), title: Text('Open in another app'))),
            ],
          ),
        ],
      ),
      body: PdfViewer.file(
        _path,
        key: ValueKey(_path), // reload after editing
        controller: _controller,
        params: PdfViewerParams(
          backgroundColor: Colors.grey.shade700,
          pagePaintCallbacks: [_searcher.pageTextMatchPaintCallback],
          onViewerReady: (document, controller) => setState(() {
            _pageCount = document.pages.length;
            _page = controller.pageNumber ?? 1;
          }),
          onPageChanged: (page) => setState(() => _page = page),
          viewerOverlayBuilder: (context, size, handleLinkTap) => [
            // Page indicator; tap to jump to a page.
            Positioned(
              right: 12,
              bottom: 16,
              child: GestureDetector(
                onTap: _goToPageDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(16)),
                  child: Text(
                    '${_page ?? 1} / $_pageCount',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ],
          errorBannerBuilder: (context, error, stackTrace, documentRef) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Could not open this PDF.\n$error',
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searcher.removeListener(_onSearch);
    _searcher.dispose();
    _searchField.dispose();
    super.dispose();
  }
}
