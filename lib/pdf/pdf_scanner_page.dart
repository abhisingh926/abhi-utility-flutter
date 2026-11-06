import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:image_picker/image_picker.dart';

import 'pdf_builder.dart';
import 'pdf_store.dart';
import 'pdf_viewer_screen.dart';

/// PDF Scanner: scan documents or pick photos, arrange the pages, create a PDF.
class PdfScannerPage extends StatefulWidget {
  const PdfScannerPage({super.key});

  @override
  State<PdfScannerPage> createState() => _PdfScannerPageState();
}

class _ScanPage {
  _ScanPage(this.path);
  final String path;
  int quarterTurns = 0;
  final key = UniqueKey();
}

class _PdfScannerPageState extends State<PdfScannerPage> {
  final List<_ScanPage> _pages = [];
  final _nameController = TextEditingController();
  bool _pageNumbers = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _resetName();
  }

  void _resetName() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    _nameController.text = 'Scan ${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}-${two(n.minute)}';
  }

  // ---- Adding pages --------------------------------------------------------------

  Future<void> _scan() async {
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: {DocumentFormat.jpeg},
        mode: ScannerMode.full, // crop, filters, clean-up
        pageLimit: 100,
        isGalleryImport: true,
      ),
    );
    try {
      final result = await scanner.scanDocument();
      final images = result.images ?? [];
      setState(() => _pages.addAll(images.map((p) => _ScanPage(p.replaceFirst('file://', '')))));
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('DocumentScanner error: code=${e.code} message=${e.message} details=${e.details}\n'
          'native stacktrace: ${e.stacktrace}');
      // Cancelled by the user, or the scanner module isn't ready yet.
      if (!(e.message ?? '').toLowerCase().contains('cancel')) {
        _snack('Scanner error (${e.code}): ${e.message ?? e.details ?? 'unknown'}');
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('DocumentScanner failure: $e\n$st');
      _snack('Scanner error: $e');
    } finally {
      scanner.close();
    }
  }

  Future<void> _pickImages() async {
    try {
      final files = await ImagePicker().pickMultiImage(maxWidth: 2200, maxHeight: 2200, imageQuality: 85);
      setState(() => _pages.addAll(files.map((f) => _ScanPage(f.path))));
    } on PlatformException catch (e) {
      _snack('Could not open gallery: ${e.message}');
    }
  }

  // ---- Page order ("numbering") ------------------------------------------------------

  void _reorder(int oldIndex, int newIndex) {
    // onReorderItem already adjusts newIndex for the removed item.
    setState(() => _pages.insert(newIndex, _pages.removeAt(oldIndex)));
  }

  /// Tap a page number to type its new position.
  Future<void> _moveTo(int index) async {
    final controller = TextEditingController(text: '${index + 1}');
    final target = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Move page ${index + 1} to'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Page number (1–${_pages.length})',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, int.tryParse(controller.text)),
            child: const Text('Move'),
          ),
        ],
      ),
    );
    if (target == null) return;
    final to = (target - 1).clamp(0, _pages.length - 1);
    if (to == index) return;
    setState(() => _pages.insert(to, _pages.removeAt(index)));
  }

  // ---- Creating the PDF ----------------------------------------------------------------

  Future<void> _create() async {
    final name = _nameController.text.trim().isEmpty ? 'Scan' : _nameController.text.trim();
    final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    setState(() => _busy = true);
    try {
      final bytes = await buildPdf(
        [for (final p in _pages) (path: p.path, quarterTurns: p.quarterTurns)],
        pageNumbers: _pageNumbers,
        title: name,
      );
      final pdf = await PdfStore.save(bytes, safeName, _pages.length);
      if (!mounted) return;
      setState(() {
        _pages.clear();
        _resetName();
      });
      _showCreated(pdf, bytes.length);
    } catch (e) {
      _snack('Could not create PDF: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showCreated(RecentPdf pdf, int size) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: Colors.green, size: 48),
        title: const Text('PDF created'),
        content: Text('${pdf.name}\n${pdf.pages} page${pdf.pages == 1 ? '' : 's'} · '
            '${(size / 1024 / 1024).toStringAsFixed(1)} MB\n\nSaved in Downloads/AbhiUtility'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              PdfStore.share(pdf.uri);
            },
            child: const Text('Share'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _openCreated(pdf);
            },
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }

  /// Shows a PDF just created in the viewer.
  Future<void> _openCreated(RecentPdf pdf) async {
    try {
      final path = await PdfStore.localCopy(pdf.uri);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PdfViewerScreen(path: path, title: pdf.name, savedUri: pdf.uri),
      ));
    } catch (e) {
      _snack('Could not open PDF: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- UI ----------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return _pages.isEmpty ? _startView(context) : _editorView(context);
  }

  Widget _startView(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Create a PDF', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('Scan papers with the camera or pick photos, arrange the pages, and save as PDF.',
            style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _BigButton(
                icon: Icons.document_scanner_outlined,
                label: 'Scan document',
                subtitle: 'Camera · auto crop',
                onTap: _scan,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _BigButton(
                icon: Icons.photo_library_outlined,
                label: 'From gallery',
                subtitle: 'Pick many photos',
                onTap: _pickImages,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Card(
          child: ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Your PDFs'),
            subtitle: const Text('PDFs you create are saved in Downloads/AbhiUtility and listed in the PDF Viewer tab.'),
          ),
        ),
      ],
    );
  }

  Widget _editorView(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        header: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'PDF name',
                  suffixText: '.pdf',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _scan,
                      icon: const Icon(Icons.document_scanner_outlined),
                      label: const Text('Scan more'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _pickImages,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: const Text('Add photos'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${_pages.length} page${_pages.length == 1 ? '' : 's'} · drag ☰ to reorder, '
                'or tap a page number to move it',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        itemCount: _pages.length,
        onReorderItem: _reorder,
        itemBuilder: (context, i) {
          final p = _pages[i];
          return Card(
            key: p.key,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  InkWell(
                    onTap: () => _moveTo(i),
                    borderRadius: BorderRadius.circular(20),
                    child: CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 72,
                      height: 96,
                      child: RotatedBox(
                        quarterTurns: p.quarterTurns,
                        child: Image.file(File(p.path), fit: BoxFit.cover, cacheWidth: 240),
                      ),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Rotate',
                    icon: const Icon(Icons.rotate_right),
                    onPressed: () => setState(() => p.quarterTurns = (p.quarterTurns + 1) % 4),
                  ),
                  IconButton(
                    tooltip: 'Remove page',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => setState(() => _pages.removeAt(i)),
                  ),
                  ReorderableDragStartListener(
                    index: i,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.drag_handle),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
        buildDefaultDragHandles: false,
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Print page numbers'),
                subtitle: const Text('"Page 1 of N" at the bottom of each page'),
                value: _pageNumbers,
                onChanged: (v) => setState(() => _pageNumbers = v),
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _pages.clear();
                              _resetName();
                            }),
                    child: const Text('Discard'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _create,
                      icon: _busy
                          ? const SizedBox(
                              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.picture_as_pdf),
                      label: Text(_busy ? 'Creating…' : 'Create PDF (${_pages.length} pages)'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.icon, required this.label, required this.subtitle, required this.onTap});

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 12),
          child: Column(
            children: [
              Icon(icon, size: 40, color: scheme.onPrimaryContainer),
              const SizedBox(height: 8),
              Text(label,
                  style: TextStyle(fontWeight: FontWeight.bold, color: scheme.onPrimaryContainer)),
              Text(subtitle,
                  style: TextStyle(fontSize: 12, color: scheme.onPrimaryContainer.withValues(alpha: 0.8))),
            ],
          ),
        ),
      ),
    );
  }
}
