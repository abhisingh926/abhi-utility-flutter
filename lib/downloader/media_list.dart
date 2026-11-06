import 'package:flutter/material.dart';

import 'media_finder.dart';

/// Found media grouped as Videos / Images / Audio, biggest file first, top 3
/// per group with "Show all". Used by the Downloader, the quick panel and the
/// built-in browser.
class MediaOptionsList extends StatefulWidget {
  const MediaOptionsList({super.key, required this.options, required this.onDownload, this.top = 3});

  /// Already sorted (see finalizeOptions).
  final List<MediaOption> options;
  final void Function(MediaOption option) onDownload;
  final int top;

  @override
  State<MediaOptionsList> createState() => _MediaOptionsListState();
}

class _MediaOptionsListState extends State<MediaOptionsList> {
  final Set<MediaKind> _expanded = {};

  static String size(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    if (bytes >= 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const groups = [
      (MediaKind.video, 'Videos', Icons.movie_outlined),
      (MediaKind.image, 'Images', Icons.image_outlined),
      (MediaKind.audio, 'Audio', Icons.music_note_outlined),
    ];
    final children = <Widget>[];
    for (final (kind, label, icon) in groups) {
      final items = widget.options.where((o) => o.kind == kind).toList();
      if (items.isEmpty) continue;
      final open = _expanded.contains(kind);
      final shown = open ? items : items.take(widget.top).toList();
      children.add(Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Row(
          children: [
            Icon(icon, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Text('$label (${items.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Text('biggest first', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ),
      ));
      for (final o in shown) {
        children.add(ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: SizedBox(
            width: 44,
            height: 44,
            child: o.kind == MediaKind.image
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(
                      o.url.toString(),
                      fit: BoxFit.cover,
                      cacheWidth: 120,
                      errorBuilder: (_, _, _) => Icon(icon, color: scheme.primary),
                    ),
                  )
                : Icon(icon, color: scheme.primary, size: 30),
          ),
          title: Text(o.quality, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text([o.extension.toUpperCase(), size(o.sizeBytes)].where((s) => s.isNotEmpty).join(' · ')),
          trailing: FilledButton.tonalIcon(
            onPressed: () => widget.onDownload(o),
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Download'),
          ),
        ));
      }
      if (items.length > widget.top) {
        children.add(Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => open ? _expanded.remove(kind) : _expanded.add(kind)),
            icon: Icon(open ? Icons.expand_less : Icons.expand_more),
            label: Text(open ? 'Show less' : 'Show all ${items.length} ${label.toLowerCase()}'),
          ),
        ));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}
