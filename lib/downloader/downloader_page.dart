import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../store_build.dart';
import 'browser_screen.dart';
import 'link_history.dart';
import 'media_finder.dart';
import 'media_list.dart';
import 'status_saver_screen.dart';

/// Video / image downloader: paste or share a link, pick a quality, download.
/// Downloads run in Android's DownloadManager (native side: Downloads.kt).
class DownloaderPage extends StatefulWidget {
  const DownloaderPage({super.key});

  @override
  State<DownloaderPage> createState() => DownloaderPageState();
}

class _Download {
  _Download.fromMap(Map m)
      : id = (m['id'] as num).toInt(),
        title = m['title'] as String? ?? 'Download',
        status = m['status'] as String,
        bytes = (m['bytes'] as num).toInt(),
        total = (m['total'] as num).toInt(),
        mime = m['mime'] as String?;

  final int id;
  final String title;
  final String status; // pending | running | paused | done | failed
  final int bytes;
  final int total;
  final String? mime;

  bool get active => status == 'running' || status == 'pending' || status == 'paused';
}

class DownloaderPageState extends State<DownloaderPage> with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving the app also starts the next visit with an empty link box.
    if (state == AppLifecycleState.paused && !_finding) reset();
    if (state == AppLifecycleState.resumed) _loadHistory();
  }

  static const channel = MethodChannel('abhi_utility/downloader');

  final _link = TextEditingController();
  bool _finding = false;
  String? _error;
  FindResult? _result;
  List<_Download> _downloads = [];
  bool _bubble = true;
  Timer? _poll;
  List<HistoryLink> _history = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadDownloads();
    _loadHistory();
    channel.invokeMethod<bool>('bubbleEnabled').then((v) {
      if (mounted) setState(() => _bubble = v ?? true);
    });
  }

  // ---- Entry points ------------------------------------------------------------------

  /// Called when the app is opened by "Share → Abhi Utility" or the ⬇ button.
  Future<void> handleLaunch(Map launch) async {
    if (launch['action'] == 'share') {
      _link.text = launch['text'] as String? ?? '';
      await _find();
    } else if (launch['action'] == 'bubble') {
      await _pasteAndFind(fromBubble: true);
    } else if (launch['action'] == 'status') {
      _openStatusSaver();
    }
  }

  /// Called when the user leaves the Downloader: next time it opens with an
  /// empty link box (the link is kept in Recent links).
  void reset() {
    if (!mounted) return;
    setState(() {
      _link.clear();
      _result = null;
      _error = null;
    });
    _loadHistory();
  }

  // ---- Link history -------------------------------------------------------------------

  Future<void> _loadHistory() async {
    final h = await LinkHistory.load();
    if (mounted) setState(() => _history = h);
  }

  Future<void> _removeHistory(HistoryLink l) async {
    await LinkHistory.remove(l.url);
    await _loadHistory();
    _snack('Removed from history');
  }

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear link history?'),
        content: Text('All ${_history.length} saved links will be deleted. Downloaded files are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    await LinkHistory.clear();
    await _loadHistory();
  }

  static String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    if (d.inDays < 7) return '${d.inDays} d ago';
    return '${t.day}/${t.month}/${t.year}';
  }

  void _openStatusSaver() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StatusSaverScreen()));
  }

  void _openBrowser([String? url]) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => BrowserScreen(initialUrl: url)));
  }

  Future<void> _pasteAndFind({bool fromBubble = false}) async {
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (extractUrl(clip) == null) {
      if (fromBubble && mounted) {
        _showHowTo();
      } else {
        _snack('No link in the clipboard. Copy the video\'s link first.');
      }
      return;
    }
    _link.text = clip;
    await _find();
  }

  void _showHowTo() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.link, size: 40),
        title: const Text('Copy the video link first'),
        content: const Text(
          '1. In the app or browser playing the video, tap Share → Copy link.\n'
          '2. Tap the ⬇ button again.\n\n'
          'Or tap Share → Abhi Utility to send the link here directly.',
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  // ---- Find & download --------------------------------------------------------------------

  Future<void> _find() async {
    // Hide the keyboard (also when the link arrived by Share / the ⬇ button).
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    setState(() {
      _finding = true;
      _error = null;
      _result = null;
    });
    final url = extractUrl(_link.text)?.toString();
    try {
      final r = await findMedia(_link.text);
      if (url != null) await LinkHistory.add(url, title: r.title);
      if (!mounted) return;
      setState(() => _result = r);
    } on FinderException catch (e) {
      if (url != null) await LinkHistory.add(url);
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _finding = false);
      _loadHistory();
    }
  }

  Future<void> _download(MediaOption o) async {
    final r = _result!;
    try {
      await channel.invokeMethod('start', {
        'url': o.url.toString(),
        'fileName': fileNameFor(r, o),
        'mimeType': o.mime,
        'referer': r.pageUrl.toString(),
        'userAgent': browserUserAgent,
      });
      _snack('⬇ Downloading ${o.quality} — see the notification');
      _loadDownloads();
    } on PlatformException catch (e) {
      _snack('Could not start the download: ${e.message}');
    }
  }

  Future<void> _loadDownloads() async {
    try {
      final raw = await channel.invokeListMethod<Map>('list') ?? [];
      if (!mounted) return;
      setState(() => _downloads = raw.map(_Download.fromMap).toList());
      // Refresh progress every second while something is downloading.
      _poll?.cancel();
      if (_downloads.any((d) => d.active)) {
        _poll = Timer(const Duration(seconds: 1), _loadDownloads);
      }
    } on PlatformException {
      // ignore
    }
  }

  Future<void> _fileAction(String method, _Download d) async {
    try {
      await channel.invokeMethod(method, {'id': d.id, 'mime': d.mime});
      if (method == 'remove') _loadDownloads();
    } on PlatformException catch (e) {
      _snack(e.message ?? 'Not available');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  static String _size(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    if (bytes >= 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  Widget _shortcut({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 30),
              const SizedBox(height: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(subtitle, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }

  // ---- UI ----------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _loadDownloads,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Downloader', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Save videos and images from web pages and direct links.',
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _shortcut(
                  icon: Icons.chat_outlined,
                  color: const Color(0xFF25D366),
                  title: 'WhatsApp Status',
                  subtitle: 'Save statuses you viewed',
                  onTap: _openStatusSaver,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _shortcut(
                  icon: Icons.travel_explore,
                  color: scheme.primary,
                  title: 'Browser',
                  subtitle: 'For sites that need login',
                  onTap: () => _openBrowser(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _link,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _find(),
            decoration: InputDecoration(
              hintText: 'Paste a video or image link',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.link),
              suffixIcon: IconButton(
                tooltip: 'Paste',
                icon: const Icon(Icons.content_paste),
                onPressed: () => _pasteAndFind(),
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _finding ? null : _find,
            icon: _finding
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search),
            label: Text(_finding ? 'Looking for videos…' : 'Find videos & images'),
          ),

          if (_error != null)
            Card(
              color: scheme.errorContainer,
              margin: const EdgeInsets.only(top: 12),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(Icons.info_outline, color: scheme.onErrorContainer),
                    title: Text(_error!, style: TextStyle(color: scheme.onErrorContainer)),
                  ),
                  if (extractUrl(_link.text) != null && !isBlockedHost(extractUrl(_link.text)!))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: OutlinedButton.icon(
                        onPressed: () => _openBrowser(_link.text),
                        icon: const Icon(Icons.login),
                        label: const Text('Open in built-in browser (log in there)'),
                      ),
                    ),
                ],
              ),
            ),
          if (_result != null) _results(context, _result!),

          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.download_for_offline_outlined),
                  title: const Text('Show ⬇ button while a video plays'),
                  subtitle: const Text('In browsers and social apps. Copy the link, then tap ⬇. '
                      'Drag to move it; drag it to ✕ to hide it in that app.'),
                  value: _bubble,
                  onChanged: (v) async {
                    await channel.invokeMethod('setBubbleEnabled', {'enabled': v});
                    setState(() => _bubble = v);
                  },
                ),
                const Divider(height: 1),
                const ListTile(
                  leading: Icon(Icons.share_outlined),
                  title: Text('Faster: Share → Abhi Utility'),
                  subtitle: Text('In any app or browser, share the video link to Abhi Utility.'),
                ),
              ],
            ),
          ),

          if (_history.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Text('Recent links', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  onPressed: _clearHistory,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('Clear all'),
                ),
              ],
            ),
            Card(
              child: Column(
                children: [
                  for (final l in _history.take(10))
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.history),
                      title: Text(l.title ?? l.host, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${l.host} · ${_when(l.time)}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        _link.text = l.url;
                        _find();
                      },
                      trailing: IconButton(
                        tooltip: 'Delete from history',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => _removeHistory(l),
                      ),
                    ),
                  if (_history.length > 10)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('+ ${_history.length - 10} older links',
                          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                    ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),
          Row(
            children: [
              Text('Downloads', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              IconButton(tooltip: 'Refresh', onPressed: _loadDownloads, icon: const Icon(Icons.refresh)),
            ],
          ),
          if (_downloads.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text('Downloads are saved in Downloads/AbhiUtility',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            )
          else
            for (final d in _downloads) _downloadTile(context, d),

          const SizedBox(height: 16),
          Text(
            'Download only content you own or have permission to save. '
            '${kPlayStore ? "YouTube, Instagram, Facebook, TikTok, X and streaming sites aren't supported (their terms)." : "YouTube isn't supported (YouTube's terms and Google Play's rules)."}',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _results(BuildContext context, FindResult r) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              title: Text(r.title ?? r.pageUrl.host, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(r.pageUrl.host),
            ),
            if (r.options.isEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  r.streamingOnly
                      ? 'This video is only available as a stream, so it can\'t be saved as a file.'
                      : 'No downloadable video or image found. The site may need a login or hide its videos.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
              if (!r.streamingOnly)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: OutlinedButton.icon(
                    onPressed: () => _openBrowser(r.pageUrl.toString()),
                    icon: const Icon(Icons.login),
                    label: const Text('Open in built-in browser (log in there)'),
                  ),
                ),
            ]
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: MediaOptionsList(options: r.options, onDownload: _download, streamed: r.streamingOnly),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _downloadTile(BuildContext context, _Download d) {
    final scheme = Theme.of(context).colorScheme;
    final progress = d.total > 0 ? d.bytes / d.total : null;
    final statusText = switch (d.status) {
      'done' => _size(d.total > 0 ? d.total : d.bytes),
      'failed' => 'Failed — the site may not allow downloading',
      'paused' => 'Paused (waiting for network) · ${_size(d.bytes)}',
      'pending' => 'Waiting…',
      _ => '${_size(d.bytes)}${d.total > 0 ? ' of ${_size(d.total)}' : ''}',
    };
    final isImage = d.mime?.startsWith('image/') ?? false;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            ListTile(
              leading: Icon(
                d.status == 'failed'
                    ? Icons.error_outline
                    : isImage
                        ? Icons.image_outlined
                        : Icons.movie_outlined,
                color: d.status == 'failed' ? scheme.error : scheme.primary,
              ),
              title: Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(statusText),
              onTap: d.status == 'done' ? () => _fileAction('open', d) : null,
              trailing: PopupMenuButton<String>(
                onSelected: (a) => _fileAction(a, d),
                itemBuilder: (_) => [
                  if (d.status == 'done') const PopupMenuItem(value: 'open', child: Text('Open')),
                  if (d.status == 'done') const PopupMenuItem(value: 'share', child: Text('Share')),
                  PopupMenuItem(value: 'remove', child: Text(d.active ? 'Cancel' : 'Delete')),
                ],
              ),
            ),
            if (d.active)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: LinearProgressIndicator(value: progress),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _link.dispose();
    super.dispose();
  }
}
