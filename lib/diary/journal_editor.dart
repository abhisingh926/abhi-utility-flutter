import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'diary_lock.dart';
import 'journal_store.dart';

const journalMoods = ['😄', '🙂', '😐', '😔', '😡'];

/// Write or edit one diary entry. Saves when you leave the screen.
class JournalEditor extends StatefulWidget {
  const JournalEditor({super.key, this.entry});

  /// null = new entry.
  final JournalEntry? entry;

  @override
  State<JournalEditor> createState() => _JournalEditorState();
}

class _JournalEditorState extends State<JournalEditor> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DiaryLock.relock.addListener(_closeIfLocked);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !DiaryLock.pickingPhoto) _closeIfLocked();
  }

  /// When the diary locks (app left, tab switched), save and close this entry so
  /// it isn't left open on screen.
  Future<void> _closeIfLocked() async {
    if (_closing || !await DiaryLock.isEnabled() || !mounted) return;
    final route = ModalRoute.of(context);
    Navigator.of(context).popUntil((r) => r == route); // e.g. a full-screen photo on top
    await _saveAndClose();
  }

  late final JournalEntry _e = widget.entry ??
      JournalEntry(id: DateTime.now().microsecondsSinceEpoch.toString(), date: DateTime.now());
  late final _text = TextEditingController(text: _e.text);

  /// Photos added in this session (deleted again if the entry ends up empty).
  final List<String> _added = [];
  bool _busy = false;

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _e.date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_e.date));
    setState(() {
      final t = time ?? TimeOfDay.fromDateTime(_e.date);
      _e.date = DateTime(date.year, date.month, date.day, t.hour, t.minute);
    });
  }

  Future<void> _addPhotos(ImageSource source) async {
    final picker = ImagePicker();
    DiaryLock.pickingPhoto = true; // the gallery/camera is not "leaving the diary"
    final List<XFile> files;
    try {
      files = source == ImageSource.camera
          ? [?await picker.pickImage(source: source, maxWidth: 1800, maxHeight: 1800, imageQuality: 82)]
          : await picker.pickMultiImage(maxWidth: 1800, maxHeight: 1800, imageQuality: 82);
    } finally {
      DiaryLock.pickingPhoto = false;
    }
    if (files.isEmpty) return;
    setState(() => _busy = true);
    try {
      for (final f in files) {
        final name = await JournalStore.addImage(f.path);
        _e.images.add(name);
        _added.add(name);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removePhoto(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this photo?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _e.images.remove(name));
    await JournalStore.deleteImage(name);
  }

  Future<void> _viewPhoto(String name) async {
    final file = await JournalStore.imageFile(name);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PhotoViewer(file: file)));
  }

  Future<void> _deleteEntry() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this diary entry?'),
        content: const Text('The text and its photos will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    _closing = true;
    await JournalStore.delete(_e);
    if (mounted) Navigator.pop(context, true);
  }

  bool _closing = false;

  /// Saves, then leaves (back button, back gesture or ✓).
  Future<void> _saveAndClose() async {
    if (_closing) return;
    _closing = true;
    await _save();
    if (mounted) Navigator.pop(context, true);
  }

  /// Saves (or drops an empty new entry).
  Future<void> _save() async {
    _e.text = _text.text;
    if (_e.isEmpty) {
      if (widget.entry != null) await JournalStore.delete(_e);
      for (final img in _added) {
        await JournalStore.deleteImage(img);
      }
      return;
    }
    await JournalStore.save(_e);
  }

  String _dateLabel() {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final d = _e.date;
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month - 1]} ${d.year} · '
        '${TimeOfDay.fromDateTime(d).format(context)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _closing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _saveAndClose();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.entry == null ? 'New diary entry' : 'Diary entry'),
          actions: [
            if (widget.entry != null)
              IconButton(tooltip: 'Delete entry', icon: const Icon(Icons.delete_outline), onPressed: _deleteEntry),
            IconButton(
              tooltip: 'Done',
              icon: const Icon(Icons.check),
              onPressed: _saveAndClose,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: ActionChip(
                avatar: const Icon(Icons.event, size: 18),
                label: Text(_dateLabel()),
                onPressed: _pickDate,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('Mood', style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(width: 8),
                for (final m in journalMoods)
                  GestureDetector(
                    onTap: () => setState(() => _e.mood = _e.mood == m ? null : m),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _e.mood == m ? scheme.primaryContainer : null,
                      ),
                      child: Text(m, style: TextStyle(fontSize: _e.mood == m ? 30 : 24)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              autofocus: widget.entry == null,
              minLines: 8,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Dear diary… How was your day?',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('📷 Photos', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (_busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final img in _e.images)
                  _Thumb(
                    name: img,
                    onTap: () => _viewPhoto(img),
                    onRemove: () => _removePhoto(img),
                  ),
                _AddPhotoButton(icon: Icons.photo_library_outlined, label: 'Gallery',
                    onTap: _busy ? null : () => _addPhotos(ImageSource.gallery)),
                _AddPhotoButton(icon: Icons.photo_camera_outlined, label: 'Camera',
                    onTap: _busy ? null : () => _addPhotos(ImageSource.camera)),
              ],
            ),
            const SizedBox(height: 16),
            Text('Saved automatically when you go back · stays on this phone',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DiaryLock.relock.removeListener(_closeIfLocked);
    _text.dispose();
    super.dispose();
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.name, required this.onTap, required this.onRemove});
  final String name;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 100,
      height: 100,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: onTap,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: JournalImage(name: name, cacheWidth: 300),
              ),
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: GestureDetector(
              onTap: onRemove,
              child: const CircleAvatar(
                radius: 12,
                backgroundColor: Colors.black54,
                child: Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddPhotoButton extends StatelessWidget {
  const _AddPhotoButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 100,
        height: 100,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant, width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: scheme.primary),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: scheme.primary)),
          ],
        ),
      ),
    );
  }
}

/// A diary photo by file name (loads the file path once).
class JournalImage extends StatelessWidget {
  const JournalImage({super.key, required this.name, this.cacheWidth, this.fit = BoxFit.cover});
  final String name;
  final int? cacheWidth;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File>(
      future: JournalStore.imageFile(name),
      builder: (context, snap) => snap.hasData
          ? Image.file(
              snap.data!,
              fit: fit,
              cacheWidth: cacheWidth,
              errorBuilder: (_, _, _) => const ColoredBox(
                color: Colors.black12,
                child: Center(child: Icon(Icons.broken_image)),
              ),
            )
          : const ColoredBox(color: Colors.black12),
    );
  }
}

/// Full-screen photo with pinch zoom.
class PhotoViewer extends StatelessWidget {
  const PhotoViewer({super.key, required this.file});
  final File file;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: InteractiveViewer(
        maxScale: 5,
        child: Center(child: Image.file(file)),
      ),
    );
  }
}
