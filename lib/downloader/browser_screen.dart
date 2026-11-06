import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'ad_block.dart';
import 'media_finder.dart';

/// Built-in browser for sites that need a login: the user logs in here, opens
/// the video, taps ⬇, and the download uses their login session (cookies).
/// Blocks ads, pop-ups, redirects to other sites without a tap, and links that
/// try to open other apps.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, this.initialUrl});

  final String? initialUrl;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  static const _downloader = MethodChannel('abhi_utility/downloader');

  InAppWebViewController? _web;
  late final Uri _start;
  final _address = TextEditingController();
  int _blocked = 0;
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
    final start = widget.initialUrl != null ? extractUrl(widget.initialUrl!) : null;
    _start = (start != null && !isBlockedHost(start)) ? start : Uri.parse('https://duckduckgo.com/');
    _address.text = _start.toString();
  }

  /// Decides whether the page may go to [action]'s address.
  NavigationActionPolicy _decide(NavigationAction action) {
    final url = action.request.url;
    if (url == null) return NavigationActionPolicy.CANCEL;
    // Ads often try intent:// / market:// links to open other apps or install pages.
    if (!const {'http', 'https', 'about', 'data', 'blob', 'javascript'}.contains(url.scheme)) {
      _countBlocked('Blocked a link that tried to open another app (often an ad).');
      return NavigationActionPolicy.CANCEL;
    }
    if (isBlockedHost(url)) {
      _snack(blockedMessage);
      return NavigationActionPolicy.CANCEL;
    }
    if (isAdUrl(url.toString())) {
      _countBlocked(null);
      return NavigationActionPolicy.CANCEL;
    }
    // The pop-under trick: the page jumps to another site without the user tapping.
    final current = Uri.tryParse(_address.text);
    if (action.isForMainFrame &&
        action.hasGesture == false &&
        current != null &&
        current.host.isNotEmpty &&
        siteOf(url.host) != siteOf(current.host) &&
        (action.isRedirect ?? false) == false) {
      _countBlocked('Blocked an automatic jump to ${url.host}. Tap a link to open it.');
      return NavigationActionPolicy.CANCEL;
    }
    return NavigationActionPolicy.ALLOW;
  }

  void _countBlocked(String? message) {
    setState(() => _blocked++);
    if (message != null) _snack(message);
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
    _web?.loadUrl(urlRequest: URLRequest(url: WebUri.uri(uri)));
  }

  Future<String?> _cookieFor(Uri url) => _downloader.invokeMethod<String>('cookies', {'url': url.toString()});

  Future<void> _find() async {
    setState(() => _finding = true);
    try {
      final web = _web;
      if (web == null) return;
      final raw = await web.evaluateJavascript(source: _collectJs);
      final data = jsonDecode(raw is String ? raw : '$raw') as Map<String, dynamic>;
      final pageUrl = (await web.getUrl())?.uriValue ?? Uri.parse('about:blank');
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
        if (!didPop) _web?.goBack(); // back = previous page, like a browser
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
            if (_blocked > 0)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Tooltip(
                  message: 'Ads and redirects blocked on this page',
                  child: Chip(
                    avatar: const Icon(Icons.shield_outlined, size: 16),
                    label: Text('$_blocked'),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            IconButton(tooltip: 'Reload', icon: const Icon(Icons.refresh), onPressed: () => _web?.reload()),
          ],
          bottom: _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(3),
                  child: LinearProgressIndicator(value: _progress / 100, minHeight: 3),
                )
              : null,
        ),
        body: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri.uri(_start)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            // No pop-up / new windows (ads).
            javaScriptCanOpenWindowsAutomatically: false,
            supportMultipleWindows: false,
            useShouldOverrideUrlLoading: true,
            contentBlockers: adContentBlockers(),
            mediaPlaybackRequiresUserGesture: false,
            thirdPartyCookiesEnabled: true, // some logins need them
          ),
          onWebViewCreated: (c) => _web = c,
          shouldOverrideUrlLoading: (c, action) async => _decide(action),
          onCreateWindow: (c, action) async {
            _countBlocked(null); // pop-up window
            return false;
          },
          onLoadStart: (c, url) {
            if (url != null) _address.text = url.toString();
            setState(() => _blocked = 0);
          },
          onProgressChanged: (c, p) => setState(() => _progress = p),
          onLoadStop: (c, url) async {
            if (url != null) _address.text = url.toString();
            final back = await c.canGoBack();
            if (mounted) setState(() => _canBack = back);
          },
        ),
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
