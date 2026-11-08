import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../excel/sheet_store.dart';
import 'doc_reader.dart';
import 'doc_writer.dart';

/// Word document (.docx) and text file viewer and editor.
///
/// Editing changes only what you touch: typing in a paragraph keeps the formatting
/// of its other words, and pictures, tables and everything else stay as they are.
class DocViewer extends StatefulWidget {
  const DocViewer({super.key, required this.file, this.startEditing = false});
  final SheetFile file;
  final bool startEditing;

  static Future<void> open(BuildContext context, SheetFile file, {bool remember = true, bool edit = false}) {
    if (remember) docStore.addRecent(file);
    return Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocViewer(file: file, startEditing: edit)));
  }

  @override
  State<DocViewer> createState() => _DocViewerState();
}

// ---- Editor model -------------------------------------------------------------------------

sealed class _Item {}

class _EditPara extends _Item {
  _EditPara({
    this.source,
    required String text,
    this.style = 'normal',
    this.align = 'left',
    this.bold,
    this.italic,
    this.underline,
    this.splitFromPid,
    this.splitAt,
  }) : original = text {
    ctl.text = text;
    last = text;
  }

  /// The paragraph in the file (null: added in the editor).
  final DocParagraph? source;
  final String original;
  final ctl = TextEditingController();
  final focus = FocusNode();
  String last = '';
  String style, align;
  bool? bold, italic, underline;

  /// Made by Enter in paragraph [splitFromPid] at text position [splitAt].
  final int? splitFromPid;
  final int? splitAt;

  bool styleChanged = false, alignChanged = false;
  bool boldChanged = false, italicChanged = false, underlineChanged = false;

  void dispose() {
    ctl.dispose();
    focus.dispose();
  }
}

class _EditTable extends _Item {
  _EditTable(this.rows);
  final List<List<List<_Item>>> rows;
}

bool? _allRuns(DocParagraph p, bool Function(DocRun r) test) {
  final runs = p.runs.where((r) => r.image == null && r.text.trim().isNotEmpty).toList();
  if (runs.isEmpty) return false;
  final n = runs.where(test).length;
  return n == runs.length ? true : (n == 0 ? false : null);
}

List<_Item> _toItems(List<DocBlock> blocks) => [
      for (final b in blocks)
        switch (b) {
          DocParagraph() => _EditPara(
              source: b,
              text: b.text,
              style: b.style,
              align: b.align,
              bold: _allRuns(b, (r) => r.bold),
              italic: _allRuns(b, (r) => r.italic),
              underline: _allRuns(b, (r) => r.underline && !r.link),
            ),
          DocTable() => _EditTable([
              for (final row in b.rows) [for (final cell in row) _toItems(cell)],
            ]),
        },
    ];

// ---- Screen -------------------------------------------------------------------------------

class _DocViewerState extends State<DocViewer> {
  late SheetFile _file = widget.file;
  Uint8List? _bytes;
  DocDocument? _doc;
  Object? _error;
  double _zoom = 1;

  late bool _editing = widget.startEditing;
  List<_Item> _items = [];
  final Set<int> _deleted = {};
  _EditPara? _focused;
  bool _changed = false;
  bool _saving = false;

  bool get _isText => _doc?.plainText ?? false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await docStore.read(_file);
      final doc = await readDocument(bytes, _file.name);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _doc = doc;
        _resetEditor();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _resetEditor() {
    for (final p in _allParas(_items)) {
      p.dispose();
    }
    _items = _toItems(_doc!.blocks);
    if (_items.isEmpty) _items = [_EditPara(text: '')]; // empty file: somewhere to type
    _deleted.clear();
    _focused = null;
    _changed = false;
    for (final p in _allParas(_items)) {
      _wire(p);
    }
  }

  Iterable<_EditPara> _allParas(List<_Item> items) sync* {
    for (final i in items) {
      switch (i) {
        case _EditPara():
          yield i;
        case _EditTable():
          for (final row in i.rows) {
            for (final cell in row) {
              yield* _allParas(cell);
            }
          }
      }
    }
  }

  void _wire(_EditPara p) {
    p.focus.addListener(() {
      if (p.focus.hasFocus && mounted) setState(() => _focused = p);
    });
  }

  @override
  void dispose() {
    for (final p in _allParas(_items)) {
      p.dispose();
    }
    super.dispose();
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 4)));

  /// The list a paragraph is in (the body or a table cell).
  List<_Item>? _containerOf(_EditPara p, [List<_Item>? items]) {
    for (final i in items ?? _items) {
      if (identical(i, p)) return items ?? _items;
      if (i is _EditTable) {
        for (final row in i.rows) {
          for (final cell in row) {
            final found = _containerOf(p, cell);
            if (found != null) return found;
          }
        }
      }
    }
    return null;
  }

  void _onChanged(_EditPara p) {
    final text = p.ctl.text;
    final cursor = p.ctl.selection.baseOffset;
    // Enter typed: split the paragraph at the cursor (like Word).
    if (text.length == p.last.length + 1 && cursor > 0 && cursor <= text.length && text[cursor - 1] == '\n' && !_isText ||
        (_isText && text.contains('\n'))) {
      final at = _isText ? text.indexOf('\n') : cursor - 1;
      final before = text.substring(0, at);
      final after = text.substring(at + 1);
      final container = _containerOf(p)!;
      final heading = p.style != 'normal';
      final next = _EditPara(
        text: after,
        style: heading && after.isEmpty ? 'normal' : p.style, // Enter after a heading → normal text
        align: p.align,
        bold: heading ? null : p.bold,
        italic: heading ? null : p.italic,
        underline: heading ? null : p.underline,
        splitFromPid: p.source?.pid ?? p.splitFromPid,
        splitAt: p.source != null ? at : null,
      );
      _wire(next);
      p.ctl.value = TextEditingValue(text: before, selection: TextSelection.collapsed(offset: before.length));
      p.last = before;
      setState(() {
        container.insert(container.indexOf(p) + 1, next);
        _changed = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        next.focus.requestFocus();
        next.ctl.selection = const TextSelection.collapsed(offset: 0);
      });
      return;
    }
    p.last = text;
    if (!_changed) setState(() => _changed = true);
  }

  void _addBelow(_EditPara p) {
    final container = _containerOf(p)!;
    final next = _EditPara(text: '', style: 'normal', align: p.align, splitFromPid: p.source?.pid ?? p.splitFromPid);
    _wire(next);
    setState(() {
      container.insert(container.indexOf(p) + 1, next);
      _changed = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => next.focus.requestFocus());
  }

  void _delete(_EditPara p) {
    final container = _containerOf(p)!;
    final inCell = !identical(container, _items);
    if (container.whereType<_EditPara>().length <= 1 && (inCell || container.length <= 1)) {
      // Last paragraph of a cell / the document: empty it instead.
      p.ctl.clear();
      _onChanged(p);
      return;
    }
    setState(() {
      container.remove(p);
      if (p.source != null) _deleted.add(p.source!.pid);
      _focused = null;
      _changed = true;
    });
  }

  void _setFormat(_EditPara p, void Function() change) => setState(() {
        change();
        _changed = true;
      });

  // ---- Saving ---------------------------------------------------------------------------

  /// Where a new paragraph goes: after the existing paragraph before it, else before
  /// the existing one after it (a table in between can't be an anchor).
  (int, bool) _anchorFor(List<_Item> container, int index) {
    for (var i = index - 1; i >= 0; i--) {
      final it = container[i];
      if (it is _EditTable) break;
      if (it is _EditPara && it.source != null) return (it.source!.pid, false);
    }
    for (var i = index + 1; i < container.length; i++) {
      final it = container[i];
      if (it is _EditTable) break;
      if (it is _EditPara && it.source != null) return (it.source!.pid, true);
    }
    for (var i = index - 1; i >= 0; i--) {
      final it = container[i];
      if (it is _EditPara && it.source != null) return (it.source!.pid, false);
    }
    for (var i = index + 1; i < container.length; i++) {
      final it = container[i];
      if (it is _EditPara && it.source != null) return (it.source!.pid, true);
    }
    return (-1, false);
  }

  DocEdits _collectEdits() {
    final edits = DocEdits();
    for (final pid in _deleted) {
      edits.of(pid).delete = true;
    }
    void walk(List<_Item> container) {
      // New paragraphs are listed in document order; the writer keeps that order.
      for (var i = 0; i < container.length; i++) {
        final it = container[i];
        switch (it) {
          case _EditTable():
            for (final row in it.rows) {
              for (final cell in row) {
                walk(cell);
              }
            }
          case _EditPara(source: final src?):
            final e = edits.of(src.pid);
            if (it.ctl.text != it.original) e.text = it.ctl.text;
            if (it.styleChanged) e.style = it.style;
            if (it.alignChanged) e.align = it.align;
            if (it.boldChanged) e.bold = it.bold;
            if (it.italicChanged) e.italic = it.italic;
            if (it.underlineChanged) e.underline = it.underline;
          case _EditPara():
            final (anchor, before) = _anchorFor(container, i);
            edits.inserted.add(NewParagraph(
              anchorPid: anchor,
              before: before,
              text: it.ctl.text,
              runFormatAt: anchor == it.splitFromPid ? it.splitAt : null,
              style: it.style,
              align: it.align,
              bold: it.bold,
              italic: it.italic,
              underline: it.underline,
            ));
        }
      }
    }

    walk(_items);
    return edits;
  }

  Future<bool> _save() async {
    if (!_changed || _bytes == null) return true;
    setState(() => _saving = true);
    try {
      final Uint8List bytes;
      if (_isText) {
        bytes = saveText([for (final p in _allParas(_items)) p.ctl.text]);
      } else {
        final edits = _collectEdits();
        final original = _bytes!;
        bytes = await Isolate.run(() => saveDocx(original, edits));
      }
      final (file, copied) = await docStore.save(_file, bytes);
      final doc = await readDocument(bytes, file.name);
      if (!mounted) return true;
      setState(() {
        _file = file;
        _bytes = bytes;
        _doc = doc;
        _resetEditor();
      });
      _snack(copied ? "Saved as a copy in Downloads/AbhiUtility: ${file.name} (the original can't be changed)" : '✅ Saved');
      return true;
    } catch (e) {
      if (mounted) _snack('Could not save: $e');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmLeave() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save changes?'),
        content: Text('You changed ${_file.name}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'discard'), child: const Text('Discard')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'save' && !await _save()) return;
    if (mounted) Navigator.of(context).pop();
  }

  // ---- UI -------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_changed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (_changed) Text('not saved', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          actions: [
            if (_doc != null) ...[
              if (_editing)
                _saving
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                    : IconButton(tooltip: 'Save', icon: const Icon(Icons.save_outlined), onPressed: _changed ? _save : null),
              IconButton(
                tooltip: _editing ? 'Stop editing' : 'Edit',
                icon: Icon(_editing ? Icons.edit_off_outlined : Icons.edit_outlined),
                onPressed: () => setState(() {
                  if (_editing && _changed) {
                    _snack('Save or discard your changes first');
                    return;
                  }
                  _editing = !_editing;
                  if (_editing) _resetEditor();
                }),
              ),
              PopupMenuButton<String>(
                onSelected: (a) => setState(() => _zoom = a == 'in' ? math.min(2, _zoom + 0.15) : math.max(0.7, _zoom - 0.15)),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'in', child: ListTile(leading: Icon(Icons.zoom_in), title: Text('Bigger text'))),
                  PopupMenuItem(value: 'out', child: ListTile(leading: Icon(Icons.zoom_out), title: Text('Smaller text'))),
                ],
              ),
            ],
          ],
        ),
        body: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.error_outline, size: 56, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(height: 16),
                    Text(_error is DocFormatException ? '$_error' : 'Could not open this file.\n$_error',
                        textAlign: TextAlign.center),
                  ]),
                ),
              )
            : _doc == null
                ? const Center(child: CircularProgressIndicator())
                : _page(),
        bottomNavigationBar: _editing && _doc != null ? _toolbar() : null,
      ),
    );
  }

  /// White "paper" with the document on it (documents assume black text on white).
  Widget _page() {
    final children = _editing ? _editItems(_items) : _viewBlocks(_doc!.blocks);
    return Theme(
      data: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true, brightness: Brightness.light),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Material(
                color: Colors.white,
                elevation: 1,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
                  child: DefaultTextStyle(
                    style: const TextStyle(color: Colors.black87, height: 1.35),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children.isEmpty
                          ? [const Text('This document is empty', style: TextStyle(color: Colors.black45))]
                          : children,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- View mode ----

  static const _fallbackSizes = {'title': 26.0, 'subtitle': 15.0, 'h1': 16.0, 'h2': 13.0, 'h3': 12.0};

  double _paraSize(String style, double base) {
    final fallback = _fallbackSizes[style];
    final pt = (fallback != null && base <= 12 && style != 'h3') ? fallback : base;
    return pt * 1.35 * _zoom;
  }

  TextAlign _textAlign(String a) => switch (a) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        'justify' => TextAlign.justify,
        _ => TextAlign.left,
      };

  List<Widget> _viewBlocks(List<DocBlock> blocks) => [
        for (final b in blocks)
          switch (b) {
            DocParagraph() => _viewParagraph(b),
            DocTable() => _viewTable(b),
          },
      ];

  Widget _viewParagraph(DocParagraph p) {
    final size = _paraSize(p.style, p.baseSize);
    final spans = <InlineSpan>[];
    for (final r in p.runs) {
      if (r.image != null) {
        spans.add(WidgetSpan(
          child: LayoutBuilder(builder: (context, c) {
            final w = math.min(r.imageWidth ?? c.maxWidth, c.maxWidth);
            return Image.memory(r.image!, width: w, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(Icons.broken_image));
          }),
        ));
        continue;
      }
      spans.add(TextSpan(
        text: r.text,
        style: TextStyle(
          fontSize: r.size != null ? r.size! * 1.35 * _zoom : size,
          fontWeight: r.bold ? FontWeight.bold : null,
          fontStyle: r.italic ? FontStyle.italic : null,
          decoration: TextDecoration.combine([
            if (r.underline) TextDecoration.underline,
            if (r.strike) TextDecoration.lineThrough,
          ]),
          color: r.color != null ? Color(r.color!) : null,
          backgroundColor: r.highlight != null ? Color(r.highlight!) : null,
        ),
      ));
    }
    Widget text = Text.rich(
      TextSpan(children: spans.isEmpty ? [TextSpan(text: '', style: TextStyle(fontSize: size))] : spans),
      textAlign: _textAlign(p.align),
    );
    if (p.listLabel != null) {
      text = Padding(
        padding: EdgeInsets.only(left: 18.0 * p.listLevel),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 26 * _zoom, child: Text(p.listLabel!, style: TextStyle(fontSize: size))),
          Expanded(child: text),
        ]),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (p.pageBreakBefore) const _PageBreak(),
        Padding(
          padding: EdgeInsets.only(
              bottom: (p.style == 'normal' ? 8 : 6) * _zoom, top: p.style.startsWith('h') || p.style == 'title' ? 8 * _zoom : 0),
          child: text,
        ),
      ],
    );
  }

  Widget _viewTable(DocTable t) {
    final cols = t.rows.fold<int>(0, (m, r) => math.max(m, r.length));
    if (cols == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: MediaQuery.of(context).size.width - 56),
          child: Table(
            border: TableBorder.all(color: Colors.black26),
            defaultColumnWidth: const IntrinsicColumnWidth(flex: 1),
            children: [
              for (final row in t.rows)
                TableRow(children: [
                  for (var c = 0; c < cols; c++)
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: c < row.length ? _viewBlocks(row[c]) : const [],
                        ),
                      ),
                    ),
                ]),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Edit mode ----

  List<Widget> _editItems(List<_Item> items) => [
        for (final it in items)
          switch (it) {
            _EditPara() => _editParagraph(it),
            _EditTable() => _editTable(it),
          },
      ];

  Widget _editParagraph(_EditPara p) {
    final src = p.source;
    final size = _paraSize(p.style, src?.baseSize ?? 11);
    final isFocused = identical(p, _focused);
    final images = src?.runs.where((r) => r.image != null).toList() ?? const <DocRun>[];
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        color: isFocused ? Colors.blue.withValues(alpha: 0.05) : null,
        border: Border(left: BorderSide(color: isFocused ? Colors.blue : Colors.transparent, width: 3)),
      ),
      padding: const EdgeInsets.only(left: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in images)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Opacity(
                opacity: 0.85,
                child: Image.memory(r.image!, height: 120, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox()),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (src?.listLabel != null)
                Padding(
                  padding: EdgeInsets.only(top: 2, left: 18.0 * (src?.listLevel ?? 0)),
                  child: SizedBox(width: 26 * _zoom, child: Text(src!.listLabel!, style: TextStyle(fontSize: size))),
                ),
              Expanded(
                child: TextField(
                  controller: p.ctl,
                  focusNode: p.focus,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textAlign: _textAlign(p.align),
                  textCapitalization: TextCapitalization.sentences,
                  style: TextStyle(
                    color: Colors.black87,
                    fontSize: size,
                    fontWeight: (p.bold ?? false) || p.style.startsWith('h') ? FontWeight.bold : null,
                    fontStyle: (p.italic ?? false) || p.style == 'subtitle' ? FontStyle.italic : null,
                    decoration: (p.underline ?? false) ? TextDecoration.underline : null,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 4 * _zoom),
                    hintText: identical(_items.firstOrNull, p) && p.ctl.text.isEmpty ? 'Start typing…' : null,
                    hintStyle: const TextStyle(color: Colors.black38),
                  ),
                  onChanged: (_) => _onChanged(p),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _editTable(_EditTable t) {
    final cols = t.rows.fold<int>(0, (m, r) => math.max(m, r.length));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Table(
        border: TableBorder.all(color: Colors.black26),
        children: [
          for (final row in t.rows)
            TableRow(children: [
              for (var c = 0; c < cols; c++)
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: c < row.length ? _editItems(row[c]) : const [],
                  ),
                ),
            ]),
        ],
      ),
    );
  }

  /// Formatting for the paragraph being edited.
  Widget _toolbar() {
    final p = _focused;
    final enabled = p != null && !_isText;
    final scheme = Theme.of(context).colorScheme;
    Widget toggle(IconData icon, String tip, bool? value, VoidCallback onTap) => IconButton(
          tooltip: tip,
          isSelected: value ?? false,
          style: IconButton.styleFrom(
            backgroundColor: (value ?? false) ? scheme.primaryContainer : null,
          ),
          icon: Icon(icon),
          onPressed: enabled ? onTap : null,
        );
    return Material(
      elevation: 8,
      color: scheme.surface,
      child: SafeArea(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: [
              if (!_isText) ...[
                DropdownButton<String>(
                  value: p?.style ?? 'normal',
                  underline: const SizedBox(),
                  onChanged: enabled
                      ? (v) => _setFormat(p, () {
                            p.style = v!;
                            p.styleChanged = true;
                          })
                      : null,
                  items: const [
                    DropdownMenuItem(value: 'normal', child: Text('Normal')),
                    DropdownMenuItem(value: 'title', child: Text('Title')),
                    DropdownMenuItem(value: 'subtitle', child: Text('Subtitle')),
                    DropdownMenuItem(value: 'h1', child: Text('Heading 1')),
                    DropdownMenuItem(value: 'h2', child: Text('Heading 2')),
                    DropdownMenuItem(value: 'h3', child: Text('Heading 3')),
                    // Styles the file uses that the editor doesn't offer: kept unless changed.
                    DropdownMenuItem(value: 'h4', enabled: false, child: Text('Heading 4')),
                    DropdownMenuItem(value: 'h5', enabled: false, child: Text('Heading 5')),
                    DropdownMenuItem(value: 'h6', enabled: false, child: Text('Heading 6')),
                  ],
                ),
                toggle(Icons.format_bold, 'Bold', p?.bold, () => _setFormat(p!, () {
                      p.bold = !(p.bold ?? false);
                      p.boldChanged = true;
                    })),
                toggle(Icons.format_italic, 'Italic', p?.italic, () => _setFormat(p!, () {
                      p.italic = !(p.italic ?? false);
                      p.italicChanged = true;
                    })),
                toggle(Icons.format_underlined, 'Underline', p?.underline, () => _setFormat(p!, () {
                      p.underline = !(p.underline ?? false);
                      p.underlineChanged = true;
                    })),
                IconButton(
                  tooltip: 'Alignment',
                  icon: Icon(switch (p?.align) {
                    'center' => Icons.format_align_center,
                    'right' => Icons.format_align_right,
                    'justify' => Icons.format_align_justify,
                    _ => Icons.format_align_left,
                  }),
                  onPressed: enabled
                      ? () => _setFormat(p, () {
                            const order = ['left', 'center', 'right', 'justify'];
                            p.align = order[(order.indexOf(p.align) + 1) % order.length];
                            p.alignChanged = true;
                          })
                      : null,
                ),
                const SizedBox(height: 24, child: VerticalDivider()),
              ],
              IconButton(
                tooltip: 'New paragraph below',
                icon: const Icon(Icons.playlist_add),
                onPressed: p == null ? null : () => _addBelow(p),
              ),
              IconButton(
                tooltip: 'Delete paragraph',
                icon: const Icon(Icons.delete_outline),
                onPressed: p == null ? null : () => _delete(p),
              ),
              if (p == null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text('Tap a paragraph to edit it', style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PageBreak extends StatelessWidget {
  const _PageBreak();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Expanded(child: Divider(color: Colors.black26)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('page break', style: TextStyle(fontSize: 11, color: Colors.black38)),
          ),
          Expanded(child: Divider(color: Colors.black26)),
        ]),
      );
}
