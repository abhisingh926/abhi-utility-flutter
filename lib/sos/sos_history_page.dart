import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account/legal_links.dart';

/// Every SOS on this phone, newest first (native side: SosHistory.kt): the calls,
/// the location SMS and the recording.
class SosHistoryPage extends StatefulWidget {
  const SosHistoryPage({super.key});

  static const channel = MethodChannel('abhi_utility/sos');

  /// Events from the native side (newest first). Empty on error.
  static Future<List<Map<String, dynamic>>> load() async {
    try {
      final list = await channel.invokeListMethod<Object?>('history') ?? const [];
      return [for (final e in list) if (e is Map) _deepCast(e)];
    } on PlatformException {
      return const [];
    }
  }

  static Map<String, dynamic> _deepCast(Map m) => m.map((k, v) => MapEntry(k.toString(), _castValue(v)));
  static Object? _castValue(Object? v) => v is Map ? _deepCast(v) : v is List ? v.map(_castValue).toList() : v;

  @override
  State<SosHistoryPage> createState() => _SosHistoryPageState();
}

class _SosHistoryPageState extends State<SosHistoryPage> {
  List<Map<String, dynamic>>? _events;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final events = await SosHistoryPage.load();
    if (mounted) setState(() => _events = events);
  }

  Future<void> _clear() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear SOS history?'),
        content: const Text('Deletes this list and the recordings kept on this phone. '
            'Uploaded recordings stay online until their link expires.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (yes != true) return;
    await SosHistoryPage.channel.invokeMethod('clearHistory');
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final events = _events;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SOS history'),
        actions: [
          if (events != null && events.isNotEmpty)
            IconButton(tooltip: 'Clear history', icon: const Icon(Icons.delete_sweep_outlined), onPressed: _clear),
        ],
      ),
      body: events == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: events.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(32),
                      children: const [
                        SizedBox(height: 80),
                        Icon(Icons.history, size: 56),
                        SizedBox(height: 12),
                        Text('No SOS yet', textAlign: TextAlign.center, style: TextStyle(fontSize: 18)),
                        SizedBox(height: 6),
                        Text('Every SOS started on this phone is listed here: who was called, '
                            'the location sent and the recording.',
                            textAlign: TextAlign.center),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      itemCount: events.length,
                      itemBuilder: (context, i) => _EventCard(event: events[i]),
                    ),
            ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event});
  final Map<String, dynamic> event;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final calls = (event['calls'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final location = event['location'] as Map<String, dynamic>?;
    final recording = event['recording'] as Map<String, dynamic>?;
    final started = _date(event['startedAt']);
    final (label, color, icon) = switch (event['outcome']) {
      'answered' => ('Answered', Colors.green, Icons.check_circle),
      'no_answer' => ('No one answered', scheme.error, Icons.phone_missed),
      'stopped' => ('Stopped by you', scheme.onSurfaceVariant, Icons.stop_circle_outlined),
      _ => ('In progress', scheme.primary, Icons.phone_in_talk),
    };
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 10),
              Expanded(child: Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: color, fontSize: 16))),
              Text(started == null ? '' : _formatDateTime(started),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 8),
            if (calls.isEmpty)
              Text('No calls were made.', style: TextStyle(color: scheme.onSurfaceVariant)),
            for (final c in calls) _CallRow(call: c),
            if (location != null) ...[const Divider(height: 18), _LocationRow(location: location)],
            if (recording != null) ...[const Divider(height: 18), _RecordingRow(recording: recording)],
          ],
        ),
      ),
    );
  }
}

class _CallRow extends StatelessWidget {
  const _CallRow({required this.call});
  final Map<String, dynamic> call;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = (call['name'] as String?)?.trim();
    final number = call['number'] as String? ?? '';
    final secs = call['seconds'] as int?;
    final (text, icon, color) = switch (call['result']) {
      'answered' => ('Answered', Icons.call, Colors.green),
      'no_answer' => ('No answer', Icons.call_missed_outgoing, scheme.error),
      'unconfirmed' => ('Call ended (answer not confirmed)', Icons.call_made, scheme.onSurfaceVariant),
      'not_connected' => ("Didn't connect", Icons.signal_cellular_connected_no_internet_0_bar, scheme.error),
      'failed' => ("Couldn't dial", Icons.error_outline, scheme.error),
      'stopped' => ('Stopped', Icons.stop, scheme.onSurfaceVariant),
      _ => ('Calling…', Icons.phone_forwarded, scheme.primary),
    };
    final at = _date(call['at']);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name == null || name.isEmpty ? number : '$name · $number',
                style: const TextStyle(fontWeight: FontWeight.w500)),
            Text('$text${secs != null && secs > 0 ? ' · ${_duration(secs)}' : ''}',
                style: TextStyle(fontSize: 12, color: color)),
          ]),
        ),
        if (at != null) Text(_formatTime(at), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({required this.location});
  final Map<String, dynamic> location;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lat = (location['lat'] as num?)?.toDouble();
    final lng = (location['lng'] as num?)?.toDouble();
    final sent = location['sentTo'] as int? ?? 0;
    final acc = location['accuracyM'] as int?;
    final text = [
      sent > 0 ? 'Location texted to $sent contact${sent == 1 ? '' : 's'}' : 'Location SMS could not be sent',
      if (lat == null) 'location not found',
      if (acc != null) 'within $acc m',
    ].join(' · ');
    return Row(children: [
      Icon(Icons.location_on_outlined, size: 18, color: scheme.primary),
      const SizedBox(width: 10),
      Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      if (lat != null && lng != null)
        TextButton(
          onPressed: () => LegalLinks.open(context, 'https://maps.google.com/?q=$lat,$lng'),
          child: const Text('Map'),
        ),
    ]);
  }
}

class _RecordingRow extends StatelessWidget {
  const _RecordingRow({required this.recording});
  final Map<String, dynamic> recording;

  Future<void> _playFile(BuildContext context, String path) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await SosHistoryPage.channel.invokeMethod('openRecording', {'path': path});
    } on PlatformException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message ?? 'Could not open the recording')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = recording['url'] as String?;
    final file = recording['file'] as String?;
    final fileExists = recording['fileExists'] == true;
    final smsSentTo = recording['smsSentTo'] as int?;
    final note = recording['note'] as String?;
    final text = switch (recording['status']) {
      'uploaded' => 'Video uploaded${smsSentTo != null && smsSentTo > 0 ? ' · link texted to $smsSentTo contact${smsSentTo == 1 ? '' : 's'}' : ''}',
      'uploading' => 'Video uploading…',
      'not_logged_in' => 'Video saved on this phone (not logged in, so not uploaded)',
      'no_video' => note ?? 'No video recorded',
      _ => note ?? 'Video not uploaded',
    };
    return Row(children: [
      Icon(Icons.videocam_outlined, size: 18, color: scheme.primary),
      const SizedBox(width: 10),
      Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      if (url != null)
        TextButton(onPressed: () => LegalLinks.open(context, url), child: const Text('Watch'))
      else if (file != null && fileExists)
        TextButton(onPressed: () => _playFile(context, file), child: const Text('Play')),
    ]);
  }
}

DateTime? _date(Object? ms) => ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _formatTime(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

String _formatDateTime(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final label = day == today
      ? 'Today'
      : day == today.subtract(const Duration(days: 1))
          ? 'Yesterday'
          : '${d.day} ${_months[d.month - 1]}${d.year == now.year ? '' : ' ${d.year}'}';
  return '$label, ${_formatTime(d)}';
}

String _duration(int secs) => secs < 60 ? '$secs s' : '${secs ~/ 60} min ${secs % 60} s';

/// "Last SOS: Today, 1:27 PM" for the SOS page.
String sosHistorySummary(List<Map<String, dynamic>> events) {
  if (events.isEmpty) return 'No SOS yet';
  final last = _date(events.first['startedAt']);
  return '${events.length} SOS${last == null ? '' : ' · last ${_formatDateTime(last)}'}';
}
