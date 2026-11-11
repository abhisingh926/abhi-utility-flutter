import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../account/api_client.dart';
import '../account/profile_page.dart';
import '../applock/accessibility_disclosure.dart';
import '../store_build.dart';
import 'sos_history_page.dart';

const _sosChannel = MethodChannel('abhi_utility/sos');

/// Gives the native SOS code an upload key for the logged-in account, when the SOS
/// recording is on and the key is missing or belongs to another account. Called
/// when the SOS page opens and whenever the account changes.
Future<bool> syncSosUploadKey({bool force = false}) async {
  try {
    final s = await _sosChannel.invokeMapMethod<String, dynamic>('status');
    if (s == null || s['record'] != true) return true;
    final api = ApiClient.instance;
    await api.load();
    final user = api.user.value;
    if (user == null || !api.isLoggedIn) {
      await _sosChannel.invokeMethod('setUpload', <String, dynamic>{});
      return false;
    }
    if (!force && s['uploadUserId'] == user.id) return true;
    final j = await api.json('POST', '/api/v1/sos/key');
    await _sosChannel.invokeMethod('setUpload', {
      'key': j['key'],
      'baseUrl': ApiClient.baseUrl,
      'userId': user.id,
      'name': user.name ?? '',
    });
    return true;
  } catch (_) {
    return false; // offline: tried again next time
  }
}

/// SOS: draw an "S" on the lock screen and the SOS contacts are called one after
/// another until someone answers. Runs natively (Sos.kt, in ReelCounterService).
class SosPage extends StatefulWidget {
  const SosPage({super.key});

  @override
  State<SosPage> createState() => SosPageState();
}

class SosContact {
  SosContact(this.name, this.number);
  SosContact.fromMap(Map m)
      : name = (m['name'] ?? '') as String,
        number = (m['number'] ?? '') as String;

  final String name;
  final String number;

  String get label => name.isEmpty ? number : name;
  Map<String, String> toMap() => {'name': name, 'number': number};
}

class SosPageState extends State<SosPage> {
  static const _channel = MethodChannel('abhi_utility/sos');

  bool _loaded = false;
  bool _on = false;
  bool _permissions = false;
  bool _service = false;
  bool _mouseKeys = false;
  bool _active = false;
  bool _drawing = false; // finger on the practice pad: don't scroll
  bool _smsLocation = false;
  bool _record = false;
  bool _smsPermissions = false;
  bool _recordPermissions = false;
  int? _uploadUserId;
  String _historySummary = '';
  List<SosContact> _contacts = [];
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    refresh();
    // Back from Accessibility / app settings: show the new state.
    _lifecycle = AppLifecycleListener(onResume: refresh);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    _apply(await _channel.invokeMapMethod<String, dynamic>('status'));
    if (_record && await syncSosUploadKey()) _apply(await _channel.invokeMapMethod<String, dynamic>('status'));
    final summary = sosHistorySummary(await SosHistoryPage.load());
    if (mounted) setState(() => _historySummary = summary);
  }

  Future<void> _openHistory() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SosHistoryPage()));
    refresh(); // history may have been cleared
  }

  void _apply(Map<String, dynamic>? s) {
    if (s == null || !mounted) return;
    setState(() {
      _loaded = true;
      _on = s['on'] as bool;
      _permissions = s['permissions'] as bool;
      _service = s['service'] as bool;
      _mouseKeys = s['mouseKeys'] as bool? ?? false;
      _active = s['active'] as bool;
      _contacts = [for (final m in (s['contacts'] as List)) SosContact.fromMap(m as Map)];
      _smsLocation = s['smsLocation'] as bool? ?? false;
      _record = s['record'] as bool? ?? false;
      _smsPermissions = s['smsLocationPermissions'] as bool? ?? false;
      _recordPermissions = s['recordPermissions'] as bool? ?? false;
      _uploadUserId = s['uploadUserId'] as int?;
    });
  }

  /// "If no one answers" switches. The recording needs a login (it is uploaded).
  Future<void> _setNoAnswer({bool? sms, bool? record}) async {
    final wantRecord = record ?? _record;
    if (record == true) {
      final api = ApiClient.instance;
      if (!api.isLoggedIn) {
        _snack('Log in first: the recording is uploaded to your account so your contacts can open the link.',
            action: SnackBarAction(label: 'Log in', onPressed: () => ProfilePage.open(context)));
        return;
      }
    }
    _apply(await _channel.invokeMapMethod<String, dynamic>(
        'setNoAnswer', {'smsLocation': sms ?? _smsLocation, 'record': wantRecord}));
    if (record == true && !await syncSosUploadKey(force: true)) {
      _snack('Could not reach the server to set up uploads. Check your internet and try again.');
      _apply(await _channel.invokeMapMethod<String, dynamic>('setNoAnswer', {'smsLocation': _smsLocation, 'record': false}));
      return;
    }
    if (record == false) await _channel.invokeMethod('setUpload', <String, dynamic>{});
    await refresh();
    final missing = (_smsLocation && !_smsPermissions) || (_record && !_recordPermissions);
    if (missing && mounted) {
      _snack('Allow SMS, location, camera and microphone so this works.', action: SnackBarAction(
        label: 'Settings',
        onPressed: () => _channel.invokeMethod('openAppSettings'),
      ));
    }
  }

  Future<void> _setOn(bool on) async {
    if (on && _contacts.isEmpty) {
      _snack('Add at least one SOS contact first.');
      return;
    }
    if (on && !_permissions) {
      await _askPermissions();
      if (!_permissions) return;
    }
    _apply(await _channel.invokeMapMethod<String, dynamic>('setOn', {'on': on}));
    if (on && !_service) _snack('Turn on the Abhi Utility accessibility service so SOS works on the lock screen.');
  }

  Future<void> _askPermissions() async {
    _apply(await _channel.invokeMapMethod<String, dynamic>('requestPermissions'));
    if (!_permissions && mounted) {
      _snack(kPlayStore
          ? 'SOS needs the Phone permission. Allow it in App settings.'
          : 'SOS needs Phone and Call log permissions. Allow them in App settings.', action: SnackBarAction(
        label: 'Settings',
        onPressed: () => _channel.invokeMethod('openAppSettings'),
      ));
    }
  }

  Future<void> _saveContacts(List<SosContact> list) async {
    _apply(await _channel.invokeMapMethod<String, dynamic>(
        'setContacts', {'contacts': [for (final c in list) c.toMap()]}));
    // No contacts left: SOS can't do anything.
    if (list.isEmpty && _on) await _setOn(false);
  }

  Future<void> _pickContact() async {
    final m = await _channel.invokeMapMethod<String, dynamic>('pickContact');
    if (m == null) return;
    final c = SosContact.fromMap(m);
    if (c.number.trim().isEmpty) return;
    await _saveContacts([..._contacts, c]);
  }

  Future<void> _typeContact() async {
    final name = TextEditingController();
    final number = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add SOS contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name (optional)'),
            ),
            TextField(
              controller: number,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone number'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true || number.text.trim().isEmpty) return;
    await _saveContacts([..._contacts, SosContact(name.text.trim(), number.text.trim())]);
  }

  void _snack(String msg, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), action: action));
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        physics: _drawing ? const NeverScrollableScrollPhysics() : const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // ---- Explanation ----
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(colors: [Color(0xFFB71C1C), Color(0xFFE53935)]),
            ),
            child: const Row(
              children: [
                Icon(Icons.sos, color: Colors.white, size: 44),
                SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Draw a big "S" at the top of the lock screen, over the clock. The phone vibrates and calls '
                    'your SOS contacts one by one until someone answers.',
                    style: TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          if (_active)
            Card(
              color: scheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.phone_in_talk),
                title: const Text('SOS is calling your contacts'),
                trailing: FilledButton(
                  onPressed: () async {
                    await _channel.invokeMethod('stop');
                    await refresh();
                  },
                  child: const Text('Stop'),
                ),
              ),
            ),

          // ---- On / off ----
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.lock_outline),
              title: const Text('SOS on the lock screen', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(_on ? 'On' : 'Off'),
              value: _on,
              onChanged: _setOn,
            ),
          ),

          // ---- What is still missing ----
          if (!_service)
            _Warning(
              text: 'The Abhi Utility accessibility service is off. SOS needs it to work on the lock screen.',
              button: 'Turn on',
              onPressed: () => openAccessibilityWithConsent(context),
            ),
          if (_mouseKeys)
            _Warning(
              text: 'Android\'s "Mouse keys" is on. On this phone it can freeze the whole phone right after an SOS '
                  '("not responding – Wait / Close app"). Turn it off in Accessibility unless you use a keyboard '
                  'to move the pointer (Interaction and dexterity, or Physical keyboard → Mouse keys).',
              button: 'Open settings',
              onPressed: () => _channel.invokeMethod('openAccessibilitySettings'),
            ),
          if (!_permissions)
            _Warning(
              text: kPlayStore
                  ? 'Allow Phone, so SOS can call your contacts and see when a call ends.'
                  : 'Allow Phone and Call log, so SOS can call and know when a contact answers.',
              button: 'Allow',
              onPressed: _askPermissions,
            ),

          // ---- Contacts ----
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
            child: Row(
              children: [
                Text('SOS contacts', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text('Called in this order', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (_contacts.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('No SOS contacts yet.', style: TextStyle(color: scheme.onSurfaceVariant)),
            )
          else
            Card(
              child: ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                onReorderItem: (from, to) {
                  final list = List.of(_contacts);
                  list.insert(to, list.removeAt(from));
                  _saveContacts(list);
                },
                children: [
                  for (var i = 0; i < _contacts.length; i++)
                    ListTile(
                      key: ValueKey('$i${_contacts[i].number}'),
                      leading: CircleAvatar(child: Text('${i + 1}')),
                      title: Text(_contacts[i].label),
                      subtitle: _contacts[i].name.isEmpty ? null : Text(_contacts[i].number),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _saveContacts(List.of(_contacts)..removeAt(i)),
                          ),
                          ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _pickContact,
                  icon: const Icon(Icons.contacts),
                  label: const Text('From contacts'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _typeContact,
                  icon: const Icon(Icons.dialpad),
                  label: const Text('Type number'),
                ),
              ),
            ],
          ),

          // ---- If no one answers ----
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 4),
            child: Text('If no one answers', style: Theme.of(context).textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
                'After every contact has been called twice without an answer. '
                'SMS are sent from your SIM (normal SMS charges).',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.location_on_outlined),
                  title: const Text('Text my location'),
                  subtitle: const Text('Sends a Google Maps link of where you are to every SOS contact.'),
                  value: _smsLocation,
                  onChanged: (v) => _setNoAnswer(sms: v),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.videocam_outlined),
                  title: const Text('Record 30 s of video and sound'),
                  subtitle: const Text(
                      'Records with the back camera over the lock screen, uploads it to your account and '
                      'texts the private link to your SOS contacts. Links expire after 30 days.'),
                  value: _record,
                  onChanged: (v) => _setNoAnswer(record: v),
                ),
              ],
            ),
          ),
          if ((_smsLocation && !_smsPermissions) || (_record && !_recordPermissions))
            _Warning(
              text: 'Allow SMS, location${_record ? ', camera and microphone' : ''} for this to work.',
              button: 'Allow',
              onPressed: () => _setNoAnswer(),
            ),
          if (_record && ApiClient.instance.user.value != null && _uploadUserId != ApiClient.instance.user.value!.id)
            _Warning(
              text: 'Uploads are not set up for this account yet (no internet?).',
              button: 'Retry',
              onPressed: () => _setNoAnswer(record: true),
            ),
          if (_record && ApiClient.instance.user.value == null)
            _Warning(
              text: 'You are logged out, so the recording can\'t be uploaded. Log in to turn it back on.',
              button: 'Log in',
              onPressed: () => ProfilePage.open(context),
            ),

          // ---- History ----
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 4),
            child: Text('History', style: Theme.of(context).textTheme.titleMedium),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.history),
              title: const Text('SOS history'),
              subtitle: Text(_historySummary.isEmpty ? 'Calls, location SMS and recordings' : _historySummary),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openHistory,
            ),
          ),

          // ---- Practice ----
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 4),
            child: Text('Practice', style: Theme.of(context).textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text('Draw an S here to check it is recognised. Nobody is called from this box.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
          _PracticePad(channel: _channel, onDrawing: (d) => setState(() => _drawing = d)),
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({required this.text, required this.button, required this.onPressed});
  final String text;
  final String button;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
            TextButton(onPressed: onPressed, child: Text(button)),
          ],
        ),
      ),
    );
  }
}

/// Box to practise the "S"; the same check as the lock screen (Sos.isS).
class _PracticePad extends StatefulWidget {
  const _PracticePad({required this.channel, required this.onDrawing});
  final MethodChannel channel;
  final ValueChanged<bool> onDrawing;

  @override
  State<_PracticePad> createState() => _PracticePadState();
}

class _PracticePadState extends State<_PracticePad> {
  final List<Offset> _points = [];
  bool? _ok;

  Future<void> _check() async {
    final flat = [for (final p in _points) ...[p.dx, p.dy]];
    final ok = await widget.channel.invokeMethod<bool>('isS', {'points': flat}) ?? false;
    if (mounted) setState(() => _ok = ok);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _ok == null ? scheme.outline : (_ok! ? Colors.green : scheme.error);
    return Column(
      children: [
        // Raw pointer events + the page stops scrolling while a finger is down here.
        Listener(
          onPointerDown: (e) {
            widget.onDrawing(true);
            setState(() {
              _points
                ..clear()
                ..add(e.localPosition);
              _ok = null;
            });
          },
          onPointerMove: (e) => setState(() => _points.add(e.localPosition)),
          onPointerUp: (_) {
            widget.onDrawing(false);
            _check();
          },
          onPointerCancel: (_) => widget.onDrawing(false),
          child: Container(
            height: 260,
            decoration: BoxDecoration(
              border: Border.all(color: color, width: 2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: CustomPaint(painter: _TrailPainter(_points, color), size: Size.infinite),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          switch (_ok) {
            null => 'Draw an S from top to bottom',
            true => '✅ S recognised: this would start SOS',
            false => '❌ Not an S. Try a bigger S, from top-right to bottom-left',
          },
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _TrailPainter extends CustomPainter {
  _TrailPainter(this.points, this.color);
  final List<Offset> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_TrailPainter old) => true;
}
