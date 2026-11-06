import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A PDF saved in Downloads/AbhiUtility.
class RecentPdf {
  RecentPdf(this.name, this.uri, this.pages, this.created);
  RecentPdf.fromJson(Map<String, dynamic> j)
      : name = j['name'] as String,
        uri = j['uri'] as String,
        pages = j['pages'] as int,
        created = DateTime.parse(j['created'] as String);

  final String name;

  /// content:// uri in MediaStore.
  final String uri;
  final int pages;
  final DateTime created;

  Map<String, dynamic> toJson() =>
      {'name': name, 'uri': uri, 'pages': pages, 'created': created.toIso8601String()};
}

/// Saving, listing, opening and sharing PDFs (native side: PdfFiles.kt).
class PdfStore {
  static const channel = MethodChannel('abhi_utility/pdf');
  static const _recentKey = 'pdf_recent';

  /// Saves [bytes] to Downloads/AbhiUtility/[name].pdf and adds it to the recent list.
  static Future<RecentPdf> save(Uint8List bytes, String name, int pages) async {
    final safe = name.trim().isEmpty
        ? 'Document'
        : name.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
    final uri = await channel.invokeMethod<String>('save', {'bytes': bytes, 'name': safe});
    final pdf = RecentPdf('$safe.pdf', uri!, pages, DateTime.now());
    final list = await recents(checkExists: false);
    await _write([pdf, ...list.where((p) => p.uri != pdf.uri)].take(30).toList());
    return pdf;
  }

  /// Recent PDFs, newest first. Files deleted from Downloads are dropped.
  static Future<List<RecentPdf>> recents({bool checkExists = true}) async {
    final prefs = await SharedPreferences.getInstance();
    final all = (prefs.getStringList(_recentKey) ?? [])
        .map((s) => RecentPdf.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
    if (!checkExists) return all;
    final existing = <RecentPdf>[];
    for (final p in all) {
      if (await channel.invokeMethod<bool>('exists', {'uri': p.uri}) ?? false) existing.add(p);
    }
    if (existing.length != all.length) await _write(existing);
    return existing;
  }

  static Future<void> _write(List<RecentPdf> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentKey, list.map((p) => jsonEncode(p.toJson())).toList());
  }

  /// Copies a content:// uri into the app cache and returns a file path the viewer can open.
  static Future<String> localCopy(String uri) async =>
      (await channel.invokeMethod<String>('copyToCache', {'uri': uri}))!;

  /// Lets the user pick a PDF; returns a local path and its name (null if cancelled).
  static Future<({String path, String name})?> pickPdf() async {
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['pdf']);
    if (file == null) return null;
    final path = file.path ?? await localCopy(file.uri.toString());
    return (path: path, name: file.name);
  }

  static Future<void> openExternally(String uri) => channel.invokeMethod('open', {'uri': uri});
  static Future<void> share(String uri) => channel.invokeMethod('share', {'uri': uri});
}
