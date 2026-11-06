import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  Future<void> _start() async {
    var text = await _channel.invokeMethod<String>('sharedText');
    if (text == null || extractUrl(text) == null) {
      // ⬇ button: the clipboard can only be read once this panel has focus.
      for (var i = 0; i < 5 && (text == null || extractUrl(text) == null); i++) {
        await Future<void>.delayed(Duration(milliseconds: 150 + i * 150));
        text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      }
    }
    if (text == null || extractUrl(text) == null) {
      setState(() {
        _loading = false;
        _error = 'Copy the video\'s link first: in the app tap Share → Copy link, then tap ⬇ again.\n'
            'Or use Share → Abhi Utility.';
      });
      return;
    }
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
                        if (_result != null)
                          Text(_result!.pageUrl.host, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
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
