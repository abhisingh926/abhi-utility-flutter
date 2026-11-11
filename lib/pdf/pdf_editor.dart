import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:pdfrx/pdfrx.dart';

import 'annotate_screen.dart';
import 'annotations.dart';
import 'pdf_store.dart';

/// Result of saving in the editor: the new file (local copy) and its Downloads entry.
typedef EditorResult = ({String path, RecentPdf saved});

/// One page in the editor: a page (from this or another PDF, maybe rotated) plus
/// the marks drawn on it.
class _Item {
  _Item(this.page);
  PdfPage page;
  PageAnnotations annotations = PageAnnotations();
  final key = UniqueKey();
  ui.Image? thumb;
  int thumbRotation = -1;
}

/// Page editor: reorder, rotate, delete, insert pages (PDF or photos), annotate, save.
class PdfEditorScreen extends StatefulWidget {
  const PdfEditorScreen({super.key, required this.path, required this.title});

  final String path;
  final String title;

  @override
  State<PdfEditorScreen> createState() => _PdfEditorScreenState();
}

class _PdfEditorScreenState extends State<PdfEditorScreen> {
  /// Every document whose pages are used; kept open until the editor closes.
  final List<PdfDocument> _docs = [];
  final List<_Item> _items = [];
  bool _loading = true;
  bool _saving = false;
  bool _changed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final doc = await PdfDocument.openFile(widget.path);
      if (!mounted) {
        doc.dispose();
        return;
      }
      _docs.add(doc);
      setState(() {
        _items.addAll(doc.pages.map(_Item.new));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not open this PDF: $e';
        _loading = false;
      });
    }
  }

  Future<ui.Image?> _thumb(_Item item) async {
    if (item.thumb != null && item.thumbRotation == item.page.rotation.index) return item.thumb;
    final image = await renderPage(item.page, 240);
    item.thumb?.dispose();
    item.thumb = image;
    item.thumbRotation = item.page.rotation.index;
    return image;
  }

  void _mark() => _changed = true;

  // ---- Page operations --------------------------------------------------------------

  void _rotate(_Item item) => setState(() {
        item.page = item.page.rotatedBy(PdfPageRotation.clockwise90);
        // Marks were placed on the old orientation; keep it simple and clear them.
        item.annotations = PageAnnotations();
        _mark();
      });

  void _delete(int i) => setState(() {
        _items.removeAt(i).thumb?.dispose();
        _mark();
      });

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
            labelText: 'Page number (1–${_items.length})',
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
    final to = (target - 1).clamp(0, _items.length - 1);
    if (to == index) return;
    setState(() {
      _items.insert(to, _items.removeAt(index));
      _mark();
    });
  }

  Future<void> _annotate(_Item item, int index) async {
    final result = await Navigator.of(context).push<PageAnnotations>(MaterialPageRoute(
      builder: (_) => AnnotateScreen(
        page: item.page,
        annotations: item.annotations,
        pageLabel: 'page ${index + 1}',
      ),
    ));
    if (result == null) return;
    setState(() {
      item.annotations = result;
      _mark();
    });
  }

  Future<void> _insertPdf() async {
    final picked = await PdfStore.pickPdf();
    if (picked == null) return;
    try {
      final doc = await PdfDocument.openFile(picked.path);
      _docs.add(doc);
      setState(() {
        _items.addAll(doc.pages.map(_Item.new));
        _mark();
      });
      _snack('Added ${doc.pages.length} pages from ${picked.name}');
    } catch (e) {
      _snack('Could not open that PDF: $e');
    }
  }

  Future<void> _insertPhotos() async {
    final files = await ImagePicker().pickMultiImage(maxWidth: 2200, maxHeight: 2200, imageQuality: 85);
    if (files.isEmpty) return;
    setState(() => _saving = true);
    try {
      for (final f in files) {
        final bytes = await File(f.path).readAsBytes();
        // Decoding / re-encoding a 2200 px photo takes ~0.5–1 s: do it off the UI thread.
        final photo = await _photoToJpeg(bytes);
        if (photo == null) continue;
        // Page as wide as A4 (595 pt), height following the photo.
        const width = 595.0;
        final doc = await PdfDocument.createFromJpegData(
          photo.jpeg,
          width: width,
          height: width * photo.h / photo.w,
          sourceName: 'photo-${DateTime.now().microsecondsSinceEpoch}',
        );
        _docs.add(doc);
        _items.add(_Item(doc.pages.first));
      }
      _mark();
    } catch (e) {
      _snack('Could not add photos: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---- Save ---------------------------------------------------------------------------

  Future<void> _save() async {
    final base = widget.title.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
    final controller = TextEditingController(text: '$base (edited)');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save as new PDF'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'File name',
            suffixText: '.pdf',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null) return;

    setState(() => _saving = true);
    final temp = <PdfDocument>[];
    try {
      final pages = <PdfPage>[];
      for (var i = 0; i < _items.length; i++) {
        final item = _items[i];
        if (item.annotations.isEmpty) {
          pages.add(item.page); // untouched page: copied as-is (text stays selectable)
        } else {
          final flat = await flattenPage(item.page, item.annotations, '${DateTime.now().microsecondsSinceEpoch}-$i');
          temp.add(flat);
          pages.add(flat.pages.first);
        }
      }
      final out = await PdfDocument.createNew(sourceName: 'edited-${DateTime.now().microsecondsSinceEpoch}');
      out.pages = pages;
      final bytes = await out.encodePdf();
      await out.dispose();

      final saved = await PdfStore.save(bytes, name, pages.length);
      // Local copy so the viewer can open the result straight away.
      final dir = await Directory.systemTemp.createTemp('pdf_saved');
      final local = File('${dir.path}/${saved.name}')..writeAsBytesSync(bytes);
      if (!mounted) return;
      Navigator.pop<EditorResult>(context, (path: local.path, saved: saved));
    } catch (e) {
      _snack('Could not save: $e');
    } finally {
      for (final d in temp) {
        await d.dispose();
      }
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_changed) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits have not been saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
        ],
      ),
    );
    return discard ?? false;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- UI -------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_changed,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          _changed = false;
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit PDF'),
          actions: [
            PopupMenuButton<String>(
              tooltip: 'Insert pages',
              icon: const Icon(Icons.add),
              enabled: !_loading && !_saving,
              onSelected: (v) => v == 'pdf' ? _insertPdf() : _insertPhotos(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'pdf', child: ListTile(leading: Icon(Icons.picture_as_pdf), title: Text('Insert another PDF'))),
                PopupMenuItem(value: 'photos', child: ListTile(leading: Icon(Icons.photo_library), title: Text('Insert photos'))),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                onPressed: _loading || _saving || _items.isEmpty ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save),
                label: const Text('Save'),
              ),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    header: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '${_items.length} pages · ✏️ to draw, write or sign · ☰ drag to reorder · '
                        'tap a number to move a page',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    buildDefaultDragHandles: false,
                    itemCount: _items.length,
                    onReorderItem: (from, to) => setState(() {
                      _items.insert(to, _items.removeAt(from));
                      _mark();
                    }),
                    itemBuilder: (context, i) {
                      final item = _items[i];
                      return Card(
                        key: item.key,
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
                              GestureDetector(
                                onTap: () => _annotate(item, i),
                                child: SizedBox(
                                  width: 80,
                                  height: 104,
                                  child: FutureBuilder<ui.Image?>(
                                    future: _thumb(item),
                                    builder: (context, snap) {
                                      final image = snap.data;
                                      if (image == null) {
                                        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                                      }
                                      return Center(
                                        child: AspectRatio(
                                          aspectRatio: image.width / image.height,
                                          child: Container(
                                            decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant)),
                                            child: Stack(
                                              fit: StackFit.expand,
                                              children: [
                                                RawImage(image: image, fit: BoxFit.fill),
                                                CustomPaint(painter: _ThumbMarks(item.annotations)),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              const Spacer(),
                              if (!item.annotations.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.only(right: 4),
                                  child: Icon(Icons.brush, size: 16, color: Colors.orange),
                                ),
                              IconButton(
                                tooltip: 'Draw / text / sign',
                                icon: const Icon(Icons.edit_note),
                                onPressed: () => _annotate(item, i),
                              ),
                              IconButton(
                                tooltip: 'Rotate',
                                icon: const Icon(Icons.rotate_right),
                                onPressed: () => _rotate(item),
                              ),
                              IconButton(
                                tooltip: 'Delete page',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: _items.length > 1 ? () => _delete(i) : null,
                              ),
                              ReorderableDragStartListener(
                                index: i,
                                child: const Padding(padding: EdgeInsets.all(6), child: Icon(Icons.drag_handle)),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }

  @override
  void dispose() {
    for (final item in _items) {
      item.thumb?.dispose();
    }
    for (final d in _docs) {
      d.dispose();
    }
    super.dispose();
  }
}

class _ThumbMarks extends CustomPainter {
  _ThumbMarks(this.a);
  final PageAnnotations a;

  @override
  void paint(Canvas canvas, Size size) => paintAnnotations(canvas, size, a);

  @override
  bool shouldRepaint(_ThumbMarks old) => true;
}

/// Any photo → JPEG (quality 85) with its size, on a background isolate (null if unreadable).
Future<({Uint8List jpeg, int w, int h})?> _photoToJpeg(Uint8List bytes) => Isolate.run(() {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      return (jpeg: img.encodeJpg(decoded, quality: 85), w: decoded.width, h: decoded.height);
    });
