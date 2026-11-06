import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ad_block.dart' show siteOf;
import 'link_history.dart';
import 'media_finder.dart';
import 'media_list.dart';

/// Quick download panel shown over another app (QuickDownloadActivity): finds
/// the video behind the shared / copied link and downloads the chosen quality
/// without leaving that app.
class QuickDownloadApp extends StatelessWidget {
  const QuickDownloadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.amber, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: Colors.amber, useMaterial3: true, brightness: Brightness.dark),
      color: Colors.transparent,
      home: const _QuickPanel(),
    );
  }
}

class _QuickPanel extends StatefulWidget {
  const _QuickPanel();

  @override
  State<_QuickPanel> createState() => _QuickPanelState();
}

class _QuickPanelState extends State<_QuickPanel> {
  static const _channel = MethodChannel('abhi_utility/quick');

  String? _link;
  FindResult? _result;
  String? _error;
  bool _loading = true;
  String? _started; // quality being downloaded

  @override
  void initState() {
    super.initState();
    _start();
  }

  /// Question shown before using a copied link that may not be this video.
  String? _confirm;
  String? _confirmLink;

  Future<void> _start() async {
    // 1. "Share → Abhi Utility": the link is exactly what the user shared.
    final shared = await _channel.invokeMethod<String>('sharedText');
    if (shared != null && extractUrl(shared) != null) return _run(shared);

    // 2. ⬇ in a browser: the address bar tells us the page.
    final info = await _channel.invokeMapMethod<String, dynamic>('launchInfo') ?? {};
    final app = (info['sourceApp'] as String?) ?? 'this app';
    final page = _pageUri(info['pageUrl'] as String?);
    if (page != null && (page.path.length > 1 || page.query.isNotEmpty)) {
      return _run(page.toString()); // full address: no copying needed
    }

    // 3. Otherwise the copied link (readable once this panel has focus).
    Map<String, dynamic>? clip;
    for (var i = 0; i < 6; i++) {
      clip = await _channel.invokeMapMethod<String, dynamic>('clipboard');
      if (extractUrl(clip?['text'] as String? ?? '') != null) break;
      await Future<void>.delayed(Duration(milliseconds: 120 + i * 120));
    }
    final text = clip?['text'] as String? ?? '';
    final copied = extractUrl(text);
    if (copied == null) {
      setState(() {
        _loading = false;
        _error = 'Copy the video\'s link first: in $app tap Share → Copy link, then tap ⬇ again.\n'
            'Or use Share → Download with Abhi Utility.';
      });
      return;
    }
    final ageMs = (clip?['ageMs'] as num?)?.toInt();
    final fresh = ageMs != null && ageMs < 2 * 60 * 1000;
    final sameSite = page != null && siteOf(copied.host) == siteOf(page.host);

    if (page != null && !sameSite) {
      // The copied link is from another site than the page on screen.
      return _ask(
        'Your copied link is from ${copied.host}, but $app is on ${page.host}.\n'
        'Copy this video\'s link (Share → Copy link) and tap ⬇ again.',
        text,
      );
    }
    if (fresh || sameSite) return _run(text);
    _ask('Use this copied link?${ageMs != null ? ' (copied ${_ago(ageMs)})' : ''}', text);
  }

  /// Address-bar text ("example.com/video/1" or a full URL) -> Uri.
  Uri? _pageUri(String? t) {
    if (t == null || t.isEmpty || t.contains(' ')) return null;
    final u = extractUrl(t) ?? (t.contains('.') ? Uri.tryParse('https://$t') : null);
    return (u == null || u.host.isEmpty) ? null : u;
  }

  static String _ago(int ms) {
    final m = ms ~/ 60000;
    if (m < 60) return '$m min ago';
    final h = m ~/ 60;
    return h < 24 ? '$h h ago' : '${h ~/ 24} days ago';
  }

  void _ask(String question, String link) => setState(() {
        _loading = false;
        _confirm = question;
        _confirmLink = link;
      });

  Future<void> _run(String text) async {
    setState(() {
      _confirm = null;
      _loading = true;
      _error = null;
    });
    _link = text;
    final url = extractUrl(text)!.toString();
    try {
      final r = await findMedia(text);
      await LinkHistory.add(url, title: r.title); // shows up in Downloader → Recent links
      if (mounted) setState(() => _result = r);
    } on FinderException catch (e) {
      await LinkHistory.add(url);
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// "pexels.com/video/sunset-123…" for showing which link is used.
  String _short(String text) {
    final u = extractUrl(text);
    if (u == null) return text;
    final s = '${u.host}${u.path}';
    return s.length > 48 ? '${s.substring(0, 48)}…' : s;
  }

  Future<void> _download(MediaOption o) async {
    final r = _result!;
    try {
      await _channel.invokeMethod('start', {
        'url': o.url.toString(),
        'fileName': fileNameFor(r, o),
        'mimeType': o.mime,
        'referer': r.pageUrl.toString(),
        'userAgent': browserUserAgent,
      });
      setState(() => _started = o.quality);
      // Show "Downloading…" briefly, then get out of the way.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await _close();
    } on PlatformException catch (e) {
      setState(() => _error = 'Could not start the download: ${e.message}');
    }
  }

  Future<void> _close() => _channel.invokeMethod('close');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        // Tap above the panel = close it.
        behavior: HitTestBehavior.opaque,
        onTap: _close,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onTap: () {}, // taps inside the panel don't close it
            child: Material(
              elevation: 12,
              color: scheme.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
              child: SafeArea(
                top: false,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Icon(Icons.download_for_offline, color: scheme.primary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _result?.title ?? 'Abhi Utility download',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                            ),
                            IconButton(tooltip: 'Close', onPressed: _close, icon: const Icon(Icons.close)),
                          ],
                        ),
                        if (_link != null && _confirm == null)
                          Text('🔗 ${_short(_link!)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                        const SizedBox(height: 8),
                        Flexible(child: _body(scheme)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    if (_started != null) {
      return ListTile(
        leading: const Icon(Icons.check_circle, color: Colors.green),
        title: Text('Downloading $_started…'),
        subtitle: const Text('Progress is in the notification. Saved to Downloads/AbhiUtility.'),
      );
    }
    if (_confirm != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_confirm!),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
            child: Text('🔗 ${_short(_confirmLink!)}', maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: OutlinedButton(onPressed: _close, child: const Text('Close'))),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => _run(_confirmLink!),
                  child: const Text('Use this link'),
                ),
              ),
            ],
          ),
        ],
      );
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            SizedBox(width: 14),
            Text('Looking for the video…'),
          ],
        ),
      );
    }
    final r = _result;
    if (_error != null || r == null || r.options.isEmpty) {
      final message = _error ??
          (r!.streamingOnly
              ? 'This video is only available as a stream, so it can\'t be saved as a file.'
              : 'No downloadable video found here. The site may need a login.');
      final canOpenApp = _link != null && !isBlockedHost(extractUrl(_link!) ?? Uri());
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(message, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          if (canOpenApp && (r == null || !r.streamingOnly))
            OutlinedButton.icon(
              onPressed: () => _channel.invokeMethod('openApp', {'text': _link}),
              icon: const Icon(Icons.login),
              label: const Text('Open in Abhi Utility (log in there)'),
            ),
        ],
      );
    }
    return SingleChildScrollView(
      child: MediaOptionsList(options: r.options, onDownload: _download),
    );
  }
}
