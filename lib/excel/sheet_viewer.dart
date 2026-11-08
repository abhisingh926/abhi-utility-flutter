import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

import 'sheet_reader.dart';
import 'sheet_store.dart';
import 'sheet_writer.dart';

/// Spreadsheet viewer and editor: frozen column letters and row numbers, sheet
/// tabs, search, zoom. In edit mode: type into cells (numbers, text, =formulas),
/// fill empty rows/columns, add sheets, and save back to the file.
class SheetViewer extends StatefulWidget {
  const SheetViewer({super.key, required this.file, this.startEditing = false});
  final SheetFile file;
  final bool startEditing;

  static Future<void> open(BuildContext context, SheetFile file, {bool remember = true, bool edit = false}) {
    if (remember) SheetStore.addRecent(file);
    return Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SheetViewer(file: file, startEditing: edit)));
  }

  @override
  State<SheetViewer> createState() => _SheetViewerState();
}

class _SheetViewerState extends State<SheetViewer> {
  late SheetFile _file = widget.file;
  Uint8List? _bytes; // the file as loaded / last saved (edits are written into it)
  late Future<Workbook> _book = _load();
  int _sheet = 0;
  (int, int)? _selected; // data row, column
  double _zoom = 1;
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  // ---- Editing ----
  late bool _editing = widget.startEditing;
  final Map<SheetData, Map<int, String>> _edits = {};
  final _editor = TextEditingController();
  final _editorFocus = FocusNode();
  bool _saving = false;

  bool get _dirty => _edits.values.any((e) => e.isNotEmpty) || _addedSheet;
  bool _addedSheet = false;

  Future<Workbook> _load() async {
    final bytes = await SheetStore.read(_file);
    _bytes = bytes;
    return readWorkbook(bytes, _file.name);
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    _editor.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  double get _rowHeight => 28 * _zoom;
  double get _fontSize => 13 * _zoom;

  /// Excel width (characters) → pixels; default column ≈ 8.43 characters.
  double _colWidth(SheetData s, int col) {
    final w = s.colWidths[col] ?? 8.43;
    if (w == 0) return 0; // hidden column
    return (w * 7 + 5).clamp(28, 480) * _zoom;
  }

  double _headerWidth(int rows) => (rows.toString().length * 9 + 20) * _zoom;

  /// Rows / columns shown: the data, plus empty ones to type into while editing.
  int _rowsShown(SheetData s) => _editing ? math.max(s.rowCount + 50, 100) : s.rowCount;
  int _colsShown(SheetData s) => _editing ? math.max(s.colCount + 10, 26) : s.colCount;

  void _selectSheet(int i) {
    setState(() {
      _sheet = i;
      _selected = null;
      _editor.clear();
    });
    if (_vertical.hasClients) _vertical.jumpTo(0);
    if (_horizontal.hasClients) _horizontal.jumpTo(0);
  }

  void _select(SheetData s, int row, int col, {bool focus = false}) {
    setState(() => _selected = (row, col));
    if (_editing) {
      _editor.text = editText(s, row, col);
      _editor.selection = TextSelection.collapsed(offset: _editor.text.length);
      if (focus) _editorFocus.requestFocus();
    }
  }

  /// Puts the edit box text into the selected cell, then moves down (like Enter in Excel).
  void _commit(SheetData s, {bool moveDown = true}) {
    final sel = _selected;
    if (sel == null) return;
    final value = _editor.text;
    if (value != editText(s, sel.$1, sel.$2)) {
      setState(() {
        setCell(s, sel.$1, sel.$2, value, csv: _isCsv);
        (_edits[s] ??= {})[SheetData.key(sel.$1, sel.$2)] = value;
      });
    }
    if (moveDown) {
      _select(s, sel.$1 + 1, sel.$2, focus: true);
      _scrollIntoView(s, sel.$1 + 1, sel.$2);
    }
  }

  bool _isCsv = false;

  /// Scrolls so that the cell is visible.
  void _scrollIntoView(SheetData s, int row, int col, {bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      var x = 0.0;
      for (var c = 0; c < col; c++) {
        x += _colWidth(s, c);
      }
      final y = row * _rowHeight;
      void go(ScrollController ctl, double target, double viewportPad) {
        if (!ctl.hasClients) return;
        final p = ctl.position;
        final visibleStart = p.pixels, visibleEnd = p.pixels + p.viewportDimension - viewportPad;
        if (!animate && target >= visibleStart && target <= visibleEnd - _rowHeight) return; // already visible
        final to = (target - viewportPad).clamp(0.0, p.maxScrollExtent);
        if (animate) {
          ctl.animateTo(to, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
        } else {
          ctl.jumpTo(to);
        }
      }

      go(_vertical, y, _rowHeight * 2);
      go(_horizontal, x, 40);
    });
  }

  Future<void> _search(Workbook book) async {
    final hit = await showModalBottomSheet<(int, int, int)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SearchSheet(book: book, currentSheet: _sheet),
    );
    if (hit == null || !mounted) return;
    if (hit.$1 != _sheet) _selectSheet(hit.$1);
    final s = book.sheets[hit.$1];
    _select(s, hit.$2, hit.$3);
    _scrollIntoView(s, hit.$2, hit.$3, animate: true);
  }

  Future<void> _addSheet(Workbook book) async {
    final ctl = TextEditingController(text: 'Sheet${book.sheets.length + 1}');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New sheet'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Sheet name'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctl.text), child: const Text('Add')),
        ],
      ),
    );
    final clean = name?.trim().replaceAll(RegExp(r'[\\/?*\[\]:]'), '');
    if (clean == null || clean.isEmpty) return;
    if (book.sheets.any((s) => s.name.toLowerCase() == clean.toLowerCase())) {
      _snack('A sheet called "$clean" already exists');
      return;
    }
    final sheet = SheetData(name: clean.length > 31 ? clean.substring(0, 31) : clean, cells: {}, rowCount: 0, colCount: 0);
    setState(() {
      book.sheets.add(sheet);
      _addedSheet = true;
    });
    _selectSheet(book.sheets.length - 1);
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 4)));

  /// Writes the edits into the file (over the original when allowed, else a copy).
  Future<bool> _save(Workbook book) async {
    final sheet = book.sheets[_sheet];
    if (_editorFocus.hasFocus) _commit(sheet, moveDown: false);
    if (!_dirty || _bytes == null) return true;
    setState(() => _saving = true);
    try {
      final original = _bytes!;
      final edits = {for (final e in _edits.entries) e.key: Map<int, String>.of(e.value)};
      final bytes = book.isCsv
          ? saveCsv(book.sheets.first, book.csvSeparator!)
          : await Isolate.run(() => saveXlsx(original, book, edits));
      final (file, copied) = await SheetStore.save(_file, bytes);
      final reloaded = await readWorkbook(bytes, file.name);
      if (!mounted) return true;
      setState(() {
        _file = file;
        _bytes = bytes;
        _edits.clear();
        _addedSheet = false;
        _book = Future.value(reloaded);
        _sheet = _sheet.clamp(0, reloaded.sheets.length - 1);
      });
      _snack(copied
          ? 'Saved as a copy in Downloads/AbhiUtility: ${file.name} (the original can\'t be changed)'
          : '✅ Saved');
      return true;
    } catch (e) {
      if (mounted) _snack('Could not save: $e');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Back with unsaved changes: save, discard or stay.
  Future<void> _confirmLeave(Workbook? book) async {
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
    if (choice == 'save' && (book == null || !await _save(book))) return;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Workbook>(
      future: _book,
      builder: (context, snap) {
        final book = snap.data;
        _isCsv = book?.isCsv ?? false;
        final sheet = book == null ? null : book.sheets[_sheet.clamp(0, book.sheets.length - 1)];
        return PopScope(
          canPop: !_dirty,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _confirmLeave(book);
          },
          child: Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (sheet != null && (book!.sheets.length > 1 || _editing))
                    Text('${sheet.name}${_dirty ? ' · not saved' : ''}', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              actions: [
                if (book != null) ...[
                  if (_editing)
                    _saving
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                        : IconButton(
                            tooltip: 'Save',
                            icon: const Icon(Icons.save_outlined),
                            onPressed: _dirty ? () => _save(book) : null,
                          ),
                  IconButton(
                    tooltip: _editing ? 'Stop editing' : 'Edit',
                    icon: Icon(_editing ? Icons.edit_off_outlined : Icons.edit_outlined),
                    onPressed: () => setState(() {
                      _editing = !_editing;
                      if (_editing && sheet != null && _selected != null) {
                        _editor.text = editText(sheet, _selected!.$1, _selected!.$2);
                      }
                      if (!_editing) _editorFocus.unfocus();
                    }),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (a) => switch (a) {
                      'search' => _search(book),
                      'zoom_in' => setState(() => _zoom = math.min(2, _zoom + 0.2)),
                      'zoom_out' => setState(() => _zoom = math.max(0.6, _zoom - 0.2)),
                      _ => null,
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'search', child: ListTile(leading: Icon(Icons.search), title: Text('Search'))),
                      PopupMenuItem(value: 'zoom_in', child: ListTile(leading: Icon(Icons.zoom_in), title: Text('Bigger'))),
                      PopupMenuItem(value: 'zoom_out', child: ListTile(leading: Icon(Icons.zoom_out), title: Text('Smaller'))),
                    ],
                  ),
                ],
              ],
            ),
            body: switch (snap.connectionState) {
              ConnectionState.done when snap.hasError => _Message(
                  icon: Icons.error_outline,
                  text: snap.error is SheetFormatException
                      ? snap.error.toString()
                      : 'Could not open this file.\n${snap.error}',
                ),
              ConnectionState.done => sheet!.isEmpty && !_editing
                  ? _Message(
                      icon: Icons.grid_off,
                      text: 'This sheet is empty',
                      action: FilledButton.icon(
                        onPressed: () => setState(() => _editing = true),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Start typing'),
                      ),
                    )
                  : Column(
                      children: [
                        _editing ? _editBar(sheet) : _cellBar(sheet),
                        Expanded(child: _grid(sheet)),
                      ],
                    ),
              _ => const Center(child: CircularProgressIndicator()),
            },
            bottomNavigationBar:
                book != null && (book.sheets.length > 1 || (_editing && !book.isCsv)) ? _sheetTabs(book) : null,
          ),
        );
      },
    );
  }

  /// View mode: "B4  1,234.50" — the selected cell's address and full text.
  Widget _cellBar(SheetData s) {
    final scheme = Theme.of(context).colorScheme;
    final sel = _selected;
    final text = sel == null ? null : s.cell(sel.$1, sel.$2);
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Text(sel == null ? '' : '${columnName(sel.$2)}${sel.$1 + 1}',
                  style: TextStyle(fontWeight: FontWeight.bold, color: scheme.primary)),
            ),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 96),
                child: SingleChildScrollView(
                  child: SelectableText(
                    sel == null ? 'Tap a cell to see all of its text · ✏️ to edit' : (text ?? ''),
                    style: TextStyle(color: sel == null ? scheme.onSurfaceVariant : null),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Edit mode: the selected cell's address and a box to type its value / =formula.
  Widget _editBar(SheetData s) {
    final scheme = Theme.of(context).colorScheme;
    final sel = _selected;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Text(sel == null ? '–' : '${columnName(sel.$2)}${sel.$1 + 1}',
                  style: TextStyle(fontWeight: FontWeight.bold, color: scheme.primary)),
            ),
            Expanded(
              child: TextField(
                controller: _editor,
                focusNode: _editorFocus,
                enabled: sel != null,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: scheme.surface,
                  border: const OutlineInputBorder(),
                  hintText: sel == null ? 'Tap a cell, then type here' : 'Number, text or =formula',
                ),
                onSubmitted: (_) => _commit(s),
              ),
            ),
            IconButton(
              tooltip: 'OK (next row)',
              icon: Icon(Icons.check_circle, color: scheme.primary),
              onPressed: sel == null ? null : () => _commit(s),
            ),
            IconButton(
              tooltip: 'Clear cell',
              icon: const Icon(Icons.backspace_outlined),
              onPressed: sel == null
                  ? null
                  : () {
                      _editor.clear();
                      _commit(s, moveDown: false);
                    },
            ),
          ],
        ),
      ),
    );
  }

  Widget _grid(SheetData s) {
    final scheme = Theme.of(context).colorScheme;
    final line = BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6));
    final headerColor = scheme.surfaceContainerHigh;
    final rows = _rowsShown(s), cols = _colsShown(s);
    final edited = _edits[s] ?? const {};

    // Every cell of a merged area must describe the same merge.
    final merged = <int, SheetMerge>{};
    for (final m in s.merges) {
      for (var r = m.row; r < m.row + m.rowSpan; r++) {
        for (var c = m.col; c < m.col + m.colSpan; c++) {
          merged[SheetData.key(r, c)] = m;
        }
      }
    }

    Widget header(String text, {bool selected = false}) => ColoredBox(
          color: selected ? scheme.primaryContainer : headerColor,
          child: Center(
            child: Text(text,
                style: TextStyle(fontSize: _fontSize * 0.9, color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
          ),
        );

    return TableView.builder(
      verticalDetails: ScrollableDetails.vertical(controller: _vertical),
      horizontalDetails: ScrollableDetails.horizontal(controller: _horizontal),
      diagonalDragBehavior: DiagonalDragBehavior.free,
      pinnedRowCount: 1,
      pinnedColumnCount: 1,
      rowCount: rows + 1,
      columnCount: cols + 1,
      columnBuilder: (i) => TableSpan(
        extent: FixedTableSpanExtent(i == 0 ? _headerWidth(rows) : _colWidth(s, i - 1)),
        foregroundDecoration: SpanDecoration(border: SpanBorder(trailing: line)),
      ),
      rowBuilder: (i) => TableSpan(
        extent: FixedTableSpanExtent(_rowHeight),
        foregroundDecoration: SpanDecoration(border: SpanBorder(trailing: line)),
      ),
      cellBuilder: (context, v) {
        final sel = _selected;
        if (v.row == 0 && v.column == 0) return TableViewCell(child: ColoredBox(color: headerColor));
        if (v.row == 0) {
          return TableViewCell(child: header(columnName(v.column - 1), selected: sel?.$2 == v.column - 1));
        }
        if (v.column == 0) return TableViewCell(child: header('${v.row}', selected: sel?.$1 == v.row - 1));

        final m = merged[SheetData.key(v.row - 1, v.column - 1)];
        final r = m?.row ?? v.row - 1;
        final c = m?.col ?? v.column - 1;
        final k = SheetData.key(r, c);
        final isSelected = sel != null && sel.$1 == r && sel.$2 == c;
        final content = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (_editing && _editorFocus.hasFocus && _selected != null) _commit(s, moveDown: false);
            _select(s, r, c);
          },
          onDoubleTap: _editing ? () => _select(s, r, c, focus: true) : null,
          child: Container(
            decoration: isSelected
                ? BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.5),
                    border: Border.all(color: scheme.primary, width: 2),
                  )
                : edited.containsKey(k)
                    ? BoxDecoration(color: Colors.amber.withValues(alpha: 0.18)) // changed, not saved yet
                    : null,
            padding: EdgeInsets.symmetric(horizontal: 4 * _zoom),
            alignment: m != null
                ? Alignment.center
                : (s.numeric.contains(k) ? Alignment.centerRight : Alignment.centerLeft),
            child: Text(
              s.cell(r, c) ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _fontSize,
                fontWeight: s.bold.contains(k) ? FontWeight.bold : null,
                fontStyle: s.formulas.containsKey(k) && (s.cell(r, c)?.startsWith('=') ?? false) ? FontStyle.italic : null,
              ),
            ),
          ),
        );
        if (m == null) return TableViewCell(child: content);
        return TableViewCell(
          rowMergeStart: m.row + 1,
          rowMergeSpan: m.rowSpan,
          columnMergeStart: m.col + 1,
          columnMergeSpan: m.colSpan,
          child: content,
        );
      },
    );
  }

  Widget _sheetTabs(Workbook book) {
    final canAdd = _editing && !book.isCsv;
    return SafeArea(
      child: SizedBox(
        height: 52,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          itemCount: book.sheets.length + (canAdd ? 1 : 0),
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) => i == book.sheets.length
              ? ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('Sheet'),
                  onPressed: () => _addSheet(book),
                )
              : ChoiceChip(
                  label: Text(book.sheets[i].name),
                  selected: i == _sheet,
                  onSelected: (_) => _selectSheet(i),
                ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(text, textAlign: TextAlign.center),
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      );
}

/// Find text in every sheet; pops with (sheet, row, column) of the chosen match.
class _SearchSheet extends StatefulWidget {
  const _SearchSheet({required this.book, required this.currentSheet});
  final Workbook book;
  final int currentSheet;

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  static const _max = 300;
  List<(int, int, int, String)> _hits = const [];
  String _query = '';

  void _find(String q) {
    _query = q.trim().toLowerCase();
    final hits = <(int, int, int, String)>[];
    if (_query.isNotEmpty) {
      // Current sheet first.
      final order = [widget.currentSheet, for (var i = 0; i < widget.book.sheets.length; i++) if (i != widget.currentSheet) i];
      outer:
      for (final si in order) {
        final s = widget.book.sheets[si];
        final rows = s.cells.keys.toList()..sort();
        for (final r in rows) {
          final row = s.cells[r]!;
          final cols = row.keys.toList()..sort();
          for (final c in cols) {
            if (row[c]!.toLowerCase().contains(_query)) {
              hits.add((si, r, c, row[c]!));
              if (hits.length >= _max) break outer;
            }
          }
        }
      }
    }
    setState(() => _hits = hits);
  }

  @override
  Widget build(BuildContext context) {
    final multi = widget.book.sheets.length > 1;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                    hintText: 'Find in this file', prefixIcon: Icon(Icons.search), border: OutlineInputBorder()),
                onChanged: _find,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _query.isEmpty
                      ? ''
                      : _hits.isEmpty
                          ? 'No matches'
                          : '${_hits.length}${_hits.length >= _max ? '+' : ''} matches',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _hits.length,
                itemBuilder: (context, i) {
                  final (si, r, c, text) = _hits[i];
                  return ListTile(
                    dense: true,
                    leading: Text('${columnName(c)}${r + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    title: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: multi ? Text(widget.book.sheets[si].name) : null,
                    onTap: () => Navigator.pop(context, (si, r, c)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
