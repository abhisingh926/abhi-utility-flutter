import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A spreadsheet on the phone: a file path, or a content:// uri.
class SheetFile {
  const SheetFile({required this.name, required this.source, this.size, this.modified});

  factory SheetFile.fromJson(Map<String, dynamic> j) => SheetFile(
        name: j['name'] as String,
        source: j['source'] as String,
        size: j['size'] as int?,
        modified: j['modified'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['modified'] as int),
      );

  final String name;
  final String source;
  final int? size;
  final DateTime? modified;

  String get extension => name.contains('.') ? name.split('.').last.toLowerCase() : '';

  /// Folder shown under the name ("Download", "WhatsApp Documents"), or null.
  String? get folder {
    if (source.startsWith('content://')) return null;
    final parts = source.split('/');
    return parts.length > 1 ? parts[parts.length - 2] : null;
  }

  Map<String, dynamic> toJson() =>
      {'name': name, 'source': source, 'size': size, 'modified': modified?.millisecondsSinceEpoch};
}

/// Finds, remembers and reads spreadsheets (Excel viewer).
class SheetStore {
  static const channel = MethodChannel('abhi_utility/sheets');
  static const _kRecent = 'excel_recent';
  static const extensions = ['xlsx', 'xlsm', 'xls', 'csv'];

  /// "All files access" granted: every spreadsheet on the phone can be listed.
  static Future<bool> hasAllFilesAccess() async =>
      await channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;

  static Future<void> requestAllFilesAccess() => channel.invokeMethod('requestAllFilesAccess');

  /// Every spreadsheet on the phone, newest first (needs [hasAllFilesAccess]).
  static Future<List<SheetFile>> scan() async {
    final raw = await channel.invokeListMethod<Map>('scan') ?? const [];
    return [
      for (final m in raw)
        SheetFile(
          name: m['name'] as String,
          // A path can be read directly; otherwise the content uri.
          source: (m['path'] as String?) ?? (m['uri'] as String),
          size: m['size'] as int?,
          modified: m['modified'] == null ? null : DateTime.fromMillisecondsSinceEpoch(m['modified'] as int),
        ),
    ];
  }

  static Future<Uint8List> read(SheetFile f) async {
    if (!f.source.contains('://')) {
      final file = File(f.source);
      if (await file.exists()) return file.readAsBytes();
    }
    final bytes = await channel.invokeMethod<Uint8List>('read', {'source': f.source});
    if (bytes == null) throw const FileSystemException('Could not read the file');
    return bytes;
  }

  /// Lets the user choose a spreadsheet (null if cancelled).
  static Future<SheetFile?> pick() async {
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: extensions);
    if (file == null) return null;
    return SheetFile(name: file.name, source: file.path ?? file.uri.toString());
  }

  static String mimeOf(String name) => switch (name.split('.').last.toLowerCase()) {
        'csv' => 'text/csv',
        'xlsm' => 'application/vnd.ms-excel.sheet.macroenabled.12',
        _ => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      };

  /// Saves over the original when Android allows it; otherwise as a copy in
  /// Downloads/AbhiUtility. Returns the file to keep editing, and true if it is a new copy.
  static Future<(SheetFile, bool)> save(SheetFile f, Uint8List bytes) async {
    try {
      await channel.invokeMethod('write', {'source': f.source, 'bytes': bytes});
      return (f, false);
    } on PlatformException {
      // Read-only (e.g. opened from WhatsApp / email): keep the original, save a copy.
    }
    return (await saveCopy(bytes, f.name), true);
  }

  /// Writes [bytes] as [name] into Downloads/AbhiUtility and remembers it.
  static Future<SheetFile> saveCopy(Uint8List bytes, String name) async {
    final uri = await channel.invokeMethod<String>('saveCopy', {'bytes': bytes, 'name': name, 'mime': mimeOf(name)});
    final copy = SheetFile(name: await nameOf(uri!), source: uri, size: bytes.length, modified: DateTime.now());
    await addRecent(copy);
    return copy;
  }

  /// File name of a content:// uri ("Open with").
  static Future<String> nameOf(String uri) async =>
      await channel.invokeMethod<String>('displayName', {'uri': uri}) ?? 'Spreadsheet';

  // ---- Recently opened ----------------------------------------------------------------

  static Future<List<SheetFile>> recents() async {
    final prefs = await SharedPreferences.getInstance();
    final list = <SheetFile>[];
    for (final s in prefs.getStringList(_kRecent) ?? const <String>[]) {
      try {
        final f = SheetFile.fromJson(jsonDecode(s) as Map<String, dynamic>);
        // Deleted files drop off the list (content uris can't be checked cheaply).
        if (f.source.contains('://') || await File(f.source).exists()) list.add(f);
      } catch (_) {}
    }
    return list;
  }

  static Future<void> addRecent(SheetFile f) async {
    final prefs = await SharedPreferences.getInstance();
    final list = (await recents()).where((r) => r.source != f.source).toList()..insert(0, f);
    await prefs.setStringList(_kRecent, list.take(15).map((r) => jsonEncode(r.toJson())).toList());
  }

  static Future<void> removeRecent(SheetFile f) async {
    final prefs = await SharedPreferences.getInstance();
    final list = (await recents()).where((r) => r.source != f.source).toList();
    await prefs.setStringList(_kRecent, list.map((r) => jsonEncode(r.toJson())).toList());
  }
}
