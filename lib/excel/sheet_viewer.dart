import 'package:flutter/material.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

import 'sheet_reader.dart';
import 'sheet_store.dart';

/// Read-only spreadsheet view: frozen column letters and row numbers, sheet tabs,
/// tap a cell to see all of its text, zoom, and search.
class SheetViewer extends StatefulWidget {
  const SheetViewer({super.key, required this.file});
  final SheetFile file;

  static Future<void> open(BuildContext context, SheetFile file, {bool remember = true}) {
    if (remember) SheetStore.addRecent(file);
    return Navigator.of(context).push(MaterialPageRoute(builder: (_) => SheetViewer(file: file)));
  }

  @override
  State<SheetViewer> createState() => _SheetViewerState();
}

class _SheetViewerState extends State<SheetViewer> {
  late final Future<Workbook> _book = _load();
  int _sheet = 0;
  (int, int)? _selected; // data row, column
  double _zoom = 1;
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  Future<Workbook> _load() async => readWorkbook(await SheetStore.read(widget.file), widget.file.name);

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
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

  double _headerWidth(SheetData s) => (s.rowCount.toString().length * 9 + 20) * _zoom;

  void _selectSheet(int i) {
    setState(() {
      _sheet = i;
      _selected = null;
    });
    if (_vertical.hasClients) _vertical.jumpTo(0);
    if (_horizontal.hasClients) _horizontal.jumpTo(0);
  }

  /// Scrolls so that the cell is visible and selects it.
  void _jumpTo(SheetData s, int row, int col) {
    setState(() => _selected = (row, col));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      var x = 0.0;
      for (var c = 0; c < col; c++) {
        x += _colWidth(s, c);
      }
      final y = row * _rowHeight;
      if (_vertical.hasClients) {
        _vertical.animateTo((y - _rowHeight * 2).clamp(0, _vertical.position.maxScrollExtent),
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
      if (_horizontal.hasClients) {
        _horizontal.animateTo((x - 40).clamp(0, _horizontal.position.maxScrollExtent),
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
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
    _jumpTo(book.sheets[hit.$1], hit.$2, hit.$3);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Workbook>(
      future: _book,
      builder: (context, snap) {
        final book = snap.data;
        final sheet = book == null ? null : book.sheets[_sheet.clamp(0, book.sheets.length - 1)];
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (sheet != null && book!.sheets.length > 1)
                  Text(sheet.name, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            actions: [
              if (book != null) ...[
                IconButton(tooltip: 'Search', icon: const Icon(Icons.search), onPressed: () => _search(book)),
                IconButton(
                  tooltip: 'Smaller',
                  icon: const Icon(Icons.zoom_out),
                  onPressed: _zoom <= 0.6 ? null : () => setState(() => _zoom -= 0.2),
                ),
                IconButton(
                  tooltip: 'Bigger',
                  icon: const Icon(Icons.zoom_in),
                  onPressed: _zoom >= 2 ? null : () => setState(() => _zoom += 0.2),
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
            ConnectionState.done => sheet!.isEmpty
                ? const _Message(icon: Icons.grid_off, text: 'This sheet is empty')
                : Column(
                    children: [
                      _cellBar(sheet),
                      Expanded(child: _grid(sheet)),
                    ],
                  ),
            _ => const Center(child: CircularProgressIndicator()),
          },
          bottomNavigationBar: book != null && book.sheets.length > 1 ? _sheetTabs(book) : null,
        );
      },
    );
  }

  /// "B4  1,234.50": the selected cell's address and full text.
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
                    sel == null ? 'Tap a cell to see all of its text' : (text ?? ''),
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

  Widget _grid(SheetData s) {
    final scheme = Theme.of(context).colorScheme;
    final line = BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6));
    final headerColor = scheme.surfaceContainerHigh;

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
      rowCount: s.rowCount + 1,
      columnCount: s.colCount + 1,
      columnBuilder: (i) => TableSpan(
        extent: FixedTableSpanExtent(i == 0 ? _headerWidth(s) : _colWidth(s, i - 1)),
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
          onTap: () => setState(() => _selected = (r, c)),
          child: Container(
            decoration: isSelected
                ? BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.5),
                    border: Border.all(color: scheme.primary, width: 2),
                  )
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
    return SafeArea(
      child: SizedBox(
        height: 52,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          itemCount: book.sheets.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) => ChoiceChip(
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
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

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
