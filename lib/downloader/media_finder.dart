import 'dart:async';
import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../store_build.dart';

/// Finds downloadable videos, images and audio behind a link.
///
/// Works with direct media links and ordinary web pages (Open Graph / Twitter
/// tags, <video>/<source> tags, JSON-LD, links and video URLs in scripts).
/// YouTube is refused (YouTube's terms and Google Play policy); the Play build also
/// refuses the social / streaming sites in [_socialHosts].

enum MediaKind { video, audio, image }

class MediaOption {
  MediaOption({required this.url, required this.kind, this.height, this.label, this.mime, this.sizeBytes});

  final Uri url;
  MediaKind kind;
  int? height;
  String? label;
  String? mime;
  int? sizeBytes;

  /// "1080p", "720p", "HD", "Image", …
  String get quality {
    if (kind == MediaKind.image) return height != null ? 'Image · ${height}px' : 'Image';
    if (height != null) return '${height}p';
    if (label != null && label!.trim().isNotEmpty) return label!.trim();
    return switch (kind) { MediaKind.image => 'Image', MediaKind.audio => 'Audio', MediaKind.video => 'Video' };
  }

  String get extension {
    final fromMime = _extFromMime(mime);
    if (fromMime != null) return fromMime;
    final m = RegExp(r'\.([a-z0-9]{2,5})$', caseSensitive: false).firstMatch(url.path);
    if (m != null) return m.group(1)!.toLowerCase();
    return switch (kind) { MediaKind.image => 'jpg', MediaKind.audio => 'mp3', MediaKind.video => 'mp4' };
  }
}

class FindResult {
  FindResult({required this.pageUrl, required this.title, required this.options, required this.streamingOnly});

  final Uri pageUrl;
  final String? title;
  final List<MediaOption> options;

  /// The page has a video, but only as a stream (HLS/DASH) that can't be saved as one file.
  final bool streamingOnly;
}

class FinderException implements Exception {
  FinderException(this.message);
  final String message;
  @override
  String toString() => message;
}

const browserUserAgent =
    'Mozilla/5.0 (Linux; Android 15; SM-S921B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';

const _youtubeHosts = ['youtube.com', 'youtu.be', 'youtube-nocookie.com', 'youtubekids.com', 'googlevideo.com'];

/// Play build only: social sites whose terms forbid downloading their videos. Play removes
/// downloaders for them on IP complaints (Intellectual Property policy).
const _socialHosts = [
  'instagram.com', 'cdninstagram.com', 'facebook.com', 'fb.watch', 'fb.com', 'fbcdn.net',
  'tiktok.com', 'tiktokcdn.com', 'tiktokv.com', 'x.com', 'twitter.com', 'twimg.com', 't.co',
  'snapchat.com', 'sc-cdn.net', 'threads.net', 'threads.com', 'pinterest.com', 'pinimg.com',
  'vimeo.com', 'vimeocdn.com', 'dailymotion.com', 'netflix.com', 'primevideo.com',
  'hotstar.com', 'jiocinema.com', 'sonyliv.com', 'zee5.com', 'spotify.com', 'jiosaavn.com',
];

const _blockedHosts = [..._youtubeHosts, if (kPlayStore) ..._socialHosts];

bool isBlockedHost(Uri u) {
  final h = u.host.toLowerCase();
  return _blockedHosts.any((b) => h == b || h.endsWith('.$b'));
}

const blockedMessage = kPlayStore
    ? "Videos from this site can't be downloaded here — its terms and Google Play's rules don't allow it."
    : "YouTube videos can't be downloaded here — YouTube's terms and Google Play's rules don't allow it. "
        'Use YouTube Premium for offline viewing.';

/// First http(s) link in shared text like "Look at this! https://…".
Uri? extractUrl(String text) {
  final m = RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false).firstMatch(text.trim());
  if (m == null) return null;
  final cleaned = m.group(0)!.replaceAll(RegExp(r'[).,;!?]+$'), '');
  return Uri.tryParse(cleaned);
}

const _videoExt = {'mp4', 'webm', 'm4v', 'mov', 'mkv', '3gp'};
const _imageExt = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'bmp'};
const _audioExt = {'mp3', 'm4a', 'aac', 'ogg', 'oga', 'wav', 'opus', 'flac'};
const _streamExt = {'m3u8', 'mpd'};

String? _extOf(Uri u) => RegExp(r'\.([a-z0-9]{2,5})$', caseSensitive: false).firstMatch(u.path)?.group(1)?.toLowerCase();

String? _extFromMime(String? mime) {
  if (mime == null) return null;
  final m = mime.split(';').first.trim().toLowerCase();
  return const {
    'video/mp4': 'mp4',
    'video/webm': 'webm',
    'video/quicktime': 'mov',
    'video/3gpp': '3gp',
    'video/x-matroska': 'mkv',
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/gif': 'gif',
    'image/webp': 'webp',
    'image/avif': 'avif',
    'audio/mpeg': 'mp3',
    'audio/mp4': 'm4a',
    'audio/aac': 'aac',
    'audio/ogg': 'ogg',
    'audio/wav': 'wav',
  }[m];
}

MediaKind? _kindFromMime(String? mime) {
  final m = mime?.toLowerCase() ?? '';
  if (m.startsWith('video/')) return MediaKind.video;
  if (m.startsWith('image/')) return MediaKind.image;
  if (m.startsWith('audio/')) return MediaKind.audio;
  return null;
}

MediaKind? _kindFromUrl(Uri u) {
  final ext = _extOf(u);
  if (ext == null) return null;
  if (_videoExt.contains(ext)) return MediaKind.video;
  if (_imageExt.contains(ext)) return MediaKind.image;
  if (_audioExt.contains(ext)) return MediaKind.audio;
  return null;
}

bool _isStream(Uri u) => _streamExt.contains(_extOf(u));

/// Height hint from a quality label ("720p", "HD", "1080") or the URL ("…_720p.mp4", "1280x720").
int? heightHint(String? text) {
  if (text == null) return null;
  final t = text.toLowerCase();
  final p = RegExp(r'(?<![0-9])(2160|1440|1080|720|540|480|360|240|144)p?(?![0-9])').firstMatch(t);
  if (p != null) return int.parse(p.group(1)!);
  final wh = RegExp(r'(?<![0-9])(\d{3,4})x(\d{3,4})(?![0-9])').firstMatch(t);
  if (wh != null) return int.parse(wh.group(2)!);
  if (RegExp(r'\b(4k|uhd)\b').hasMatch(t)) return 2160;
  if (RegExp(r'\bfhd|full ?hd\b').hasMatch(t)) return 1080;
  if (RegExp(r'\bhd\b').hasMatch(t)) return 720;
  if (RegExp(r'\bsd\b').hasMatch(t)) return 480;
  return null;
}

/// Pulls media candidates out of an HTML page. Pure function (unit-tested).
({String? title, List<MediaOption> options, bool streamingOnly}) parseMediaFromHtml(String body, Uri base) {
  final doc = html_parser.parse(body);
  final found = <String, MediaOption>{};
  var sawStream = false;

  void add(String? raw, {MediaKind? kind, int? height, String? label, String? mime}) {
    if (raw == null) return;
    var s = raw.trim().replaceAll(r'\/', '/').replaceAll(r'&', '&').replaceAll('&amp;', '&');
    if (s.isEmpty || s.startsWith('data:') || s.startsWith('blob:') || s.startsWith('javascript:')) return;
    final u = Uri.tryParse(s);
    if (u == null) return;
    final abs = base.resolveUri(u);
    if (!abs.isScheme('http') && !abs.isScheme('https')) return;
    if (isBlockedHost(abs)) return;
    if (_isStream(abs) || (mime?.contains('mpegurl') ?? false) || (mime?.contains('dash') ?? false)) {
      sawStream = true;
      return;
    }
    final k = kind ?? _kindFromMime(mime) ?? _kindFromUrl(abs);
    if (k == null) return;
    final key = abs.toString();
    final h = height ?? heightHint(label) ?? heightHint(abs.path);
    final existing = found[key];
    if (existing != null) {
      existing.height ??= h;
      existing.label ??= label;
      existing.mime ??= mime;
      return;
    }
    found[key] = MediaOption(url: abs, kind: k, height: h, label: label, mime: mime);
  }

  // Meta tags (Open Graph / Twitter cards).
  String? meta(String name) {
    for (final m in doc.getElementsByTagName('meta')) {
      final key = (m.attributes['property'] ?? m.attributes['name'] ?? '').toLowerCase();
      if (key == name) return m.attributes['content'];
    }
    return null;
  }

  int? intMeta(String name) => int.tryParse(meta(name) ?? '');

  final ogVideoHeight = intMeta('og:video:height');
  final ogVideoType = meta('og:video:type');
  for (final k in ['og:video:secure_url', 'og:video:url', 'og:video', 'twitter:player:stream']) {
    final v = meta(k);
    // og:video sometimes points to an embeddable player page: only keep real files or unknown types.
    if (v != null && (ogVideoType == null || ogVideoType.startsWith('video/') || ogVideoType.contains('mpegurl'))) {
      add(v, kind: MediaKind.video, height: ogVideoHeight, mime: ogVideoType?.startsWith('video/') == true ? ogVideoType : null);
    }
  }
  final ogImageHeight = intMeta('og:image:height');
  for (final k in ['og:image:secure_url', 'og:image:url', 'og:image', 'twitter:image', 'twitter:image:src']) {
    add(meta(k), kind: MediaKind.image, height: k.startsWith('og:') ? ogImageHeight : null);
  }

  // <video>/<audio> and their <source> children.
  for (final tag in ['video', 'audio']) {
    final kind = tag == 'video' ? MediaKind.video : MediaKind.audio;
    for (final el in doc.getElementsByTagName(tag)) {
      add(el.attributes['src'], kind: kind, height: int.tryParse(el.attributes['height'] ?? ''));
      for (final s in el.getElementsByTagName('source')) {
        final label = s.attributes['label'] ?? s.attributes['res'] ?? s.attributes['size'] ??
            s.attributes['data-res'] ?? s.attributes['data-quality'] ?? s.attributes['title'] ?? s.attributes['quality'];
        add(s.attributes['src'] ?? s.attributes['data-src'], kind: kind, label: label, mime: s.attributes['type']);
      }
    }
  }

  // Links straight to media files ("Download HD" buttons…).
  for (final a in doc.getElementsByTagName('a')) {
    final href = a.attributes['href'];
    if (href == null) continue;
    final u = Uri.tryParse(href);
    if (u == null) continue;
    final kind = _kindFromUrl(u);
    if (kind == MediaKind.video || kind == MediaKind.audio || kind == MediaKind.image) {
      add(href, kind: kind, label: a.text.trim().isEmpty ? null : a.text.trim());
    } else if (_isStream(u)) {
      sawStream = true;
    }
  }

  // All images in the page content (<img>, lazy-loaded ones, the largest srcset
  // version, <picture> sources). Icons / tiny images are skipped.
  String? largestFromSrcset(String? srcset) {
    if (srcset == null || srcset.trim().isEmpty) return null;
    String? best;
    var bestW = -1.0;
    for (final part in srcset.split(RegExp(r',\s+'))) {
      final bits = part.trim().split(RegExp(r'\s+'));
      if (bits.isEmpty || bits.first.isEmpty) continue;
      final d = bits.length > 1 ? bits[1] : '1x';
      final w = double.tryParse(d.replaceAll(RegExp(r'[wx]$'), '')) ?? 1;
      final weight = d.endsWith('x') ? w * 1000 : w;
      if (weight > bestW) {
        bestW = weight;
        best = bits.first;
      }
    }
    return best;
  }

  bool tiny(String? v) {
    final n = int.tryParse((v ?? '').replaceAll(RegExp(r'[^0-9]'), ''));
    return n != null && n < 100;
  }

  for (final img in doc.getElementsByTagName('img')) {
    final a = img.attributes;
    if (tiny(a['width']) || tiny(a['height'])) continue;
    final src = largestFromSrcset(a['srcset'] ?? a['data-srcset']) ??
        a['data-src'] ?? a['data-original'] ?? a['data-lazy-src'] ?? a['data-full'] ?? a['src'];
    if (src == null || src.toLowerCase().contains('.svg')) continue;
    add(src, kind: MediaKind.image, height: int.tryParse(a['height'] ?? ''));
  }
  for (final s in doc.querySelectorAll('picture source')) {
    final src = largestFromSrcset(s.attributes['srcset']);
    if (src != null && !src.toLowerCase().contains('.svg')) add(src, kind: MediaKind.image);
  }

  // JSON-LD (VideoObject / ImageObject / AudioObject).
  void walk(dynamic node) {
    if (node is Map) {
      final type = '${node['@type']}'.toLowerCase();
      final url = node['contentUrl'];
      if (url is String) {
        final kind = type.contains('image') ? MediaKind.image : type.contains('audio') ? MediaKind.audio : MediaKind.video;
        add(url, kind: kind, height: int.tryParse('${node['height'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '')),
            mime: node['encodingFormat'] is String ? node['encodingFormat'] as String : null);
      }
      node.values.forEach(walk);
    } else if (node is List) {
      node.forEach(walk);
    }
  }

  for (final s in doc.getElementsByTagName('script')) {
    if ((s.attributes['type'] ?? '').contains('ld+json')) {
      try {
        walk(jsonDecode(s.text));
      } catch (_) {}
    }
  }

  // Video files mentioned inside scripts / JSON (many players embed them there).
  final inScripts = RegExp(
    r'''https?:(?:\\?/){2}[^\s"'<>\\]+?\.(?:mp4|webm|m4v|mov)(?:\?[^\s"'<>]*)?''',
    caseSensitive: false,
  );
  var n = 0;
  for (final m in inScripts.allMatches(body)) {
    if (++n > 40) break;
    add(m.group(0), kind: MediaKind.video);
  }
  if (RegExp(r'''\.m3u8(\?|["'\s])''').hasMatch(body)) sawStream = true;

  final title = (meta('og:title') ?? doc.getElementsByTagName('title').firstOrNull?.text)?.trim();
  final options = found.values.toList()..sort(_compare);
  return (
    title: (title == null || title.isEmpty) ? null : title,
    options: options,
    streamingOnly: sawStream && !options.any((o) => o.kind == MediaKind.video),
  );
}

/// Videos, then images, then audio; inside each group the biggest file first
/// (unknown sizes last, ordered by quality).
int _compare(MediaOption a, MediaOption b) {
  int rank(MediaKind k) => switch (k) { MediaKind.video => 0, MediaKind.image => 1, MediaKind.audio => 2 };
  final r = rank(a.kind).compareTo(rank(b.kind));
  if (r != 0) return r;
  final bySize = (b.sizeBytes ?? -1).compareTo(a.sizeBytes ?? -1);
  if (bySize != 0) return bySize;
  return (b.height ?? -1).compareTo(a.height ?? -1);
}

/// Keeps the list size-checkable: all videos/audio (max 30) and up to 30 images.
List<MediaOption> candidatesToCheck(List<MediaOption> all) => [
      ...all.where((o) => o.kind != MediaKind.image).take(30),
      ...all.where((o) => o.kind == MediaKind.image).take(30),
    ];

/// Sorts after sizes are known and drops icon-sized images (< 15 KB).
List<MediaOption> finalizeOptions(List<MediaOption> options) => options
    .where((o) => !(o.kind == MediaKind.image && o.sizeBytes != null && o.sizeBytes! < 15 * 1024))
    .toList()
  ..sort(_compare);

/// Fetches [input] (a link or text containing one) and returns what can be downloaded.
Future<FindResult> findMedia(String input, {http.Client? client}) async {
  final start = extractUrl(input);
  if (start == null) throw FinderException('No link found. Copy the video\'s link (Share → Copy link) and try again.');
  if (isBlockedHost(start)) throw FinderException(blockedMessage);

  final c = client ?? http.Client();
  try {
    // Follow redirects ourselves to know the final address (short links etc.).
    var url = start;
    http.StreamedResponse res;
    var hops = 0;
    while (true) {
      final req = http.Request('GET', url)
        ..followRedirects = false
        ..headers['User-Agent'] = browserUserAgent
        ..headers['Accept'] = 'text/html,application/xhtml+xml,*/*;q=0.8';
      res = await c.send(req).timeout(const Duration(seconds: 20));
      final loc = res.headers['location'];
      if (res.isRedirect || (res.statusCode >= 300 && res.statusCode < 400 && loc != null)) {
        await res.stream.listen(null).cancel();
        if (loc == null || ++hops > 6) throw FinderException('Too many redirects.');
        url = url.resolve(loc);
        if (isBlockedHost(url)) throw FinderException(blockedMessage);
        continue;
      }
      break;
    }
    if (res.statusCode >= 400) {
      await res.stream.listen(null).cancel();
      throw FinderException(res.statusCode == 401 || res.statusCode == 403
          ? 'This site needs a login. Open it in the built-in browser, log in, then tap ⬇ there.'
          : 'The site answered with an error (${res.statusCode}).');
    }

    final type = res.headers['content-type'];
    final directKind = _kindFromMime(type) ?? (type == null || type.contains('octet-stream') ? _kindFromUrl(url) : null);
    if (directKind != null) {
      // The link itself is the file.
      await res.stream.listen(null).cancel();
      final option = MediaOption(
        url: url,
        kind: directKind,
        mime: type?.split(';').first,
        sizeBytes: int.tryParse(res.headers['content-length'] ?? ''),
        height: heightHint(url.path),
        label: 'Original',
      );
      return FindResult(pageUrl: url, title: url.pathSegments.isEmpty ? null : url.pathSegments.last, options: [option], streamingOnly: false);
    }
    if (type != null && !type.contains('html') && !type.contains('xml')) {
      await res.stream.listen(null).cancel();
      throw FinderException('This link is not a web page or a media file.');
    }

    // Read up to 3 MB of the page.
    final bytes = <int>[];
    await for (final chunk in res.stream) {
      bytes.addAll(chunk);
      if (bytes.length > 3 * 1024 * 1024) break;
    }
    final parsed = parseMediaFromHtml(utf8.decode(bytes, allowMalformed: true), url);
    final options = candidatesToCheck(parsed.options);
    await checkSizes(c, options, referer: url.toString());
    return FindResult(
      pageUrl: url,
      title: parsed.title,
      options: finalizeOptions(options),
      streamingOnly: parsed.streamingOnly,
    );
  } on TimeoutException {
    throw FinderException('The site took too long to answer. Check your internet and try again.');
  } on FinderException {
    rethrow;
  } on Exception catch (e) {
    throw FinderException('Could not open the link: $e');
  } finally {
    if (client == null) c.close();
  }
}

/// Media found in a page the user opened in the built-in browser (maybe logged
/// in): the page's HTML plus the media addresses it actually loaded/played.
({String? title, List<MediaOption> options, bool streamingOnly}) parseBrowserPage(
  String html,
  Uri pageUrl,
  List<String> loadedUrls,
) {
  var sawBlob = false;
  final extra = StringBuffer();
  for (final u in loadedUrls) {
    if (u.startsWith('blob:')) {
      sawBlob = true; // played as a stream (MediaSource) – no single file
      continue;
    }
    extra.write('<video src="${const HtmlEscape(HtmlEscapeMode.attribute).convert(u)}"></video>');
  }
  final r = parseMediaFromHtml('$html$extra', pageUrl);
  return (
    title: r.title,
    options: r.options,
    streamingOnly: (r.streamingOnly || sawBlob) && !r.options.any((o) => o.kind == MediaKind.video),
  );
}

/// Asks each file for its size and type; drops "videos" that are really web pages.
/// [cookieFor] gives login cookies for a file (built-in browser).
Future<void> checkSizes(
  http.Client c,
  List<MediaOption> options, {
  required String referer,
  Future<String?> Function(Uri url)? cookieFor,
}) async {
  final drop = <MediaOption>{};
  // 8 at a time: fast, without flooding the site.
  for (var i = 0; i < options.length; i += 8) {
    await _checkBatch(c, options.skip(i).take(8).toList(), drop, referer, cookieFor);
  }
  options.removeWhere(drop.contains);
}

Future<void> _checkBatch(
  http.Client c,
  List<MediaOption> batch,
  Set<MediaOption> drop,
  String referer,
  Future<String?> Function(Uri url)? cookieFor,
) async {
  await Future.wait(batch.map((o) async {
    try {
      final req = http.Request('GET', o.url)
        ..headers['User-Agent'] = browserUserAgent
        ..headers['Referer'] = referer
        ..headers['Range'] = 'bytes=0-0';
      final cookie = cookieFor == null ? null : await cookieFor(o.url);
      if (cookie != null && cookie.isNotEmpty) req.headers['Cookie'] = cookie;
      final res = await c.send(req).timeout(const Duration(seconds: 8));
      await res.stream.listen(null).cancel();
      if (res.statusCode >= 400) {
        drop.add(o);
        return;
      }
      final type = res.headers['content-type'];
      if (type != null && type.contains('html')) {
        drop.add(o);
        return;
      }
      o.mime ??= _kindFromMime(type) != null ? type?.split(';').first : null;
      final range = res.headers['content-range']; // "bytes 0-0/12345"
      final total = range == null ? null : int.tryParse(range.split('/').last);
      o.sizeBytes = total ?? (res.statusCode == 200 ? int.tryParse(res.headers['content-length'] ?? '') : null);
    } catch (_) {
      // Unknown size: keep the option anyway.
    }
  }));
}

/// Safe file name like "Sunset_timelapse_720p.mp4".
String fileNameFor(FindResult r, MediaOption o) {
  var base = (r.title ?? r.pageUrl.host).replaceAll(RegExp(r'[^\w\- ]+', unicode: true), ' ').trim();
  base = base.replaceAll(RegExp(r'\s+'), '_');
  if (base.length > 60) base = base.substring(0, 60);
  if (base.isEmpty) base = 'download';
  final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  return '${base}_${o.quality.replaceAll(RegExp(r'[^\w]+'), '')}_$stamp.${o.extension}';
}
