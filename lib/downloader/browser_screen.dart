import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

import 'media_finder.dart';

/// Built-in browser for sites that need a login: the user logs in here, opens
/// the video, taps ⬇, and the download uses their login session (cookies).
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, this.initialUrl});

  final String? initialUrl;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  static const _downloader = MethodChannel('abhi_utility/downloader');

  late final WebViewController _web;
  final _address = TextEditingController();
  int _progress = 0;
  bool _canBack = false;
  bool _finding = false;

  // Collects the page HTML and every media address the page loaded or played.
  static const _collectJs = r'''
(function () {
  var urls = [];
  document.querySelectorAll('video, audio, video source, audio source').forEach(function (v) {
    if (v.currentSrc) urls.push(v.currentSrc);
    if (v.src) urls.push(v.src);
  });
  try {
    performance.getEntriesByType('resource').forEach(function (e) {
      if (/\.(mp4|webm|m4v|mov|mp3|m4a|jpg|jpeg|png|webp|gif)(\?|$)/i.test(e.name) ||
          e.initiatorType === 'video' || e.initiatorType === 'audio') urls.push(e.name);
    });
  } catch (e) {}
  var html = document.documentElement.outerHTML;
  if (html.length > 3000000) html = html.substring(0, 3000000);
  return JSON.stringify({ html: html, urls: urls, ua: navigator.userAgent, title: document.title });
})();
''';

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) {
          final uri = Uri.tryParse(req.url);
          if (uri != null && isBlockedHost(uri)) {
            _snack(blockedMessage);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onProgress: (p) => setState(() => _progress = p),
        onPageStarted: (url) => _address.text = url,
        onPageFinished: (url) async {
          _address.text = url;
          final back = await _web.canGoBack();
          if (mounted) setState(() => _canBack = back);
        },
      ));
    final start = widget.initialUrl != null ? extractUrl(widget.initialUrl!) : null;
    if (start != null && !isBlockedHost(start)) {
      _web.loadRequest(start);
    } else {
      _web.loadRequest(Uri.parse('https://duckduckgo.com/'));
    }
  }

  void _go(String text) {
    FocusManager.instance.primaryFocus?.unfocus();
    final t = text.trim();
    if (t.isEmpty) return;
    var uri = extractUrl(t) ?? (t.contains('.') && !t.contains(' ') ? Uri.tryParse('https://$t') : null);
    uri ??= Uri.https('duckduckgo.com', '/', {'q': t});
    if (isBlockedHost(uri)) {
      _snack(blockedMessage);
      return;
    }
    _web.loadRequest(uri);
  }

  Future<String?> _cookieFor(Uri url) => _downloader.invokeMethod<String>('cookies', {'url': url.toString()});

  Future<void> _find() async {
    setState(() => _finding = true);
    try {
      final raw = await _web.runJavaScriptReturningResult(_collectJs);
      // Android returns the JSON string itself JSON-encoded.
      var text = raw is String ? raw : raw.toString();
      if (text.startsWith('"')) text = jsonDecode(text) as String;
      final data = jsonDecode(text) as Map<String, dynamic>;
      final pageUrl = Uri.parse(await _web.currentUrl() ?? 'about:blank');
      final parsed = parseBrowserPage(
        data['html'] as String,
        pageUrl,
        [for (final u in (data['urls'] as List)) '$u'],
      );
      final options = parsed.options.take(25).toList();
      final client = http.Client();
      try {
        await checkSizes(client, options, referer: pageUrl.toString(), cookieFor: _cookieFor);
      } finally {
        client.close();
      }
      if (!mounted) return;
      _showResults(
        FindResult(
          pageUrl: pageUrl,
          title: parsed.title ?? (data['title'] as String?),
          options: options,
          streamingOnly: parsed.streamingOnly,
        ),
        data['ua'] as String?,
      );
    } catch (e) {
      _snack('Could not read this page: $e');
    } finally {
      if (mounted) setState(() => _finding = false);
    }
  }

  void _showResults(FindResult r, String? userAgent) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          maxChildSize: 0.9,
          builder: (context, scroll) => ListView(
            controller: scroll,
            children: [
              ListTile(
                title: Text(r.title ?? r.pageUrl.host, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(r.pageUrl.host),
              ),
              if (r.options.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    r.streamingOnly
                        ? 'This site streams its videos in small pieces, so they can\'t be saved as one file.'
                        : 'No video found yet. Start playing the video on the page, then tap ⬇ again.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              else
                for (final o in r.options)
                  ListTile(
                    leading: Icon(
                      switch (o.kind) {
                        MediaKind.video => Icons.movie_outlined,
                        MediaKind.audio => Icons.music_note_outlined,
                        MediaKind.image => Icons.image_outlined,
                      },
                      color: scheme.primary,
                    ),
                    title: Text(o.quality, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text([o.extension.toUpperCase(), _size(o.sizeBytes)].where((s) => s.isNotEmpty).join(' · ')),
                    trailing: FilledButton.tonalIcon(
                      onPressed: () async {
                        Navigator.pop(context);
                        await _download(r, o, userAgent);
                      },
                      icon: const Icon(Icons.download),
                      label: const Text('Download'),
                    ),
                  ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Future<void> _download(FindResult r, MediaOption o, String? userAgent) async {
    try {
      await _downloader.invokeMethod('start', {
        'url': o.url.toString(),
        'fileName': fileNameFor(r, o),
        'mimeType': o.mime,
        'referer': r.pageUrl.toString(),
        'userAgent': userAgent ?? browserUserAgent,
        'cookie': await _cookieFor(o.url), // logged-in downloads
      });
      _snack('⬇ Downloading ${o.quality} — see the notification');
    } on PlatformException catch (e) {
      _snack('Could not start the download: ${e.message}');
    }
  }

  static String _size(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_canBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _web.goBack(); // back = previous page, like a browser
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: TextField(
            controller: _address,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            onSubmitted: _go,
            decoration: const InputDecoration(
              hintText: 'Search or type a site',
              border: InputBorder.none,
              isDense: true,
            ),
          ),
          actions: [
            IconButton(tooltip: 'Reload', icon: const Icon(Icons.refresh), onPressed: () => _web.reload()),
          ],
          bottom: _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(3),
                  child: LinearProgressIndicator(value: _progress / 100, minHeight: 3),
                )
              : null,
        ),
        body: WebViewWidget(controller: _web),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _finding ? null : _find,
          icon: _finding
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.download),
          label: const Text('Find videos'),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }
}
