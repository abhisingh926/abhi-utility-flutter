import 'package:flutter/material.dart';

import 'diary_store.dart';

/// Daily to-do list, one page per day.
class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  DateTime _day = DiaryStore.dateOnly(DateTime.now());
  DiaryDay _data = DiaryDay();
  bool _loading = true;

  /// Unfinished tasks from yesterday (only offered when viewing today).
  List<DiaryTask> _carryOver = [];

  final _newTask = TextEditingController();
  final _newTaskFocus = FocusNode();
  TimeOfDay? _newTaskTime;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _isToday => _day == DiaryStore.dateOnly(DateTime.now());

  Future<void> _load() async {
    final data = await DiaryStore.load(_day);
    var carry = <DiaryTask>[];
    if (_isToday) {
      final yesterday = await DiaryStore.load(_day.subtract(const Duration(days: 1)));
      final todayTexts = data.tasks.map((t) => t.text).toSet();
      carry = yesterday.unfinished.where((t) => !todayTexts.contains(t.text)).toList();
    }
    if (!mounted) return;
    setState(() {
      _data = data;
      _carryOver = carry;
      _loading = false;
    });
  }

  Future<void> _save() => DiaryStore.save(_day, _data);

  void _goTo(DateTime day) {
    setState(() {
      _day = DiaryStore.dateOnly(day);
      _loading = true;
    });
    _load();
  }

  String _title() {
    final today = DiaryStore.dateOnly(DateTime.now());
    final diff = _day.difference(today).inDays;
    final date = '${_weekdays[_day.weekday - 1]}, ${_day.day} ${_months[_day.month - 1]} ${_day.year}';
    return switch (diff) {
      0 => 'Today · $date',
      -1 => 'Yesterday · $date',
      1 => 'Tomorrow · $date',
      _ => date,
    };
  }

  // ---- Tasks ------------------------------------------------------------------------

  String _fmtTime(String hhmm) {
    final parts = hhmm.split(':');
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])).format(context);
  }

  String _toHHmm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _sortTasks() {
    // Unfinished first; then by time (tasks with a time first), then important first.
    _data.tasks.sort((a, b) {
      if (a.done != b.done) return a.done ? 1 : -1;
      if ((a.time == null) != (b.time == null)) return a.time == null ? 1 : -1;
      if (a.time != null && b.time != null && a.time != b.time) return a.time!.compareTo(b.time!);
      if (a.important != b.important) return a.important ? -1 : 1;
      return 0;
    });
  }

  void _addTask() {
    final text = _newTask.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _data.tasks.add(DiaryTask(
        id: DiaryStore.newId(),
        text: text,
        time: _newTaskTime == null ? null : _toHHmm(_newTaskTime!),
      ));
      _sortTasks();
      _newTask.clear();
      _newTaskTime = null;
    });
    _save();
    _newTaskFocus.requestFocus(); // ready for the next one
  }

  void _toggle(DiaryTask t) {
    setState(() {
      t.done = !t.done;
      _sortTasks();
    });
    _save();
  }

  void _delete(DiaryTask t) {
    final index = _data.tasks.indexOf(t);
    setState(() => _data.tasks.remove(t));
    _save();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Deleted "${t.text}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            setState(() => _data.tasks.insert(index.clamp(0, _data.tasks.length), t));
            _save();
          },
        ),
      ));
  }

  Future<void> _edit(DiaryTask t) async {
    final controller = TextEditingController(text: t.text);
    var time = t.time;
    var important = t.important;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Edit task'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.schedule, size: 18),
                    label: Text(time == null ? 'Add time' : _fmtTime(time!)),
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: time == null
                            ? TimeOfDay.now()
                            : TimeOfDay(
                                hour: int.parse(time!.split(':')[0]),
                                minute: int.parse(time!.split(':')[1]),
                              ),
                      );
                      if (picked != null) setDialog(() => time = _toHHmm(picked));
                    },
                  ),
                  if (time != null)
                    IconButton(
                      tooltip: 'Remove time',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setDialog(() => time = null),
                    ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Important',
                    icon: Icon(important ? Icons.star : Icons.star_border,
                        color: important ? Colors.amber : null),
                    onPressed: () => setDialog(() => important = !important),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (result != true || controller.text.trim().isEmpty) return;
    setState(() {
      t.text = controller.text.trim();
      t.time = time;
      t.important = important;
      _sortTasks();
    });
    _save();
  }

  Future<void> _moveCarryOver() async {
    final yesterdayDate = _day.subtract(const Duration(days: 1));
    final yesterday = await DiaryStore.load(yesterdayDate);
    final ids = _carryOver.map((t) => t.id).toSet();
    // Move: add to today, remove from yesterday.
    setState(() {
      _data.tasks.addAll(_carryOver.map((t) => DiaryTask(
            id: DiaryStore.newId() + t.id,
            text: t.text,
            important: t.important,
            time: t.time,
          )));
      _sortTasks();
      _carryOver = [];
    });
    yesterday.tasks.removeWhere((t) => ids.contains(t.id));
    await DiaryStore.save(yesterdayDate, yesterday);
    await _save();
  }

  // ---- Calendar ---------------------------------------------------------------------------

  Future<void> _openCalendar() async {
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      showDragHandle: true,
      builder: (_) => _MonthCalendar(selected: _day),
    );
    if (picked != null) _goTo(picked);
  }

  // ---- UI ----------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = _data.tasks.length;
    final done = _data.doneCount;

    return Column(
      children: [
        // Day switcher.
        Material(
          color: scheme.surfaceContainer,
          child: Row(
            children: [
              IconButton(
                tooltip: 'Previous day',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _goTo(_day.subtract(const Duration(days: 1))),
              ),
              Expanded(
                child: InkWell(
                  onTap: _openCalendar,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.calendar_month, size: 18, color: scheme.primary),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(_title(),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (!_isToday)
                TextButton(onPressed: () => _goTo(DateTime.now()), child: const Text('Today')),
              IconButton(
                tooltip: 'Next day',
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _goTo(_day.add(const Duration(days: 1))),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    if (_carryOver.isNotEmpty)
                      Card(
                        color: scheme.tertiaryContainer,
                        child: ListTile(
                          leading: const Icon(Icons.redo),
                          title: Text('${_carryOver.length} unfinished task'
                              '${_carryOver.length == 1 ? '' : 's'} from yesterday'),
                          subtitle: Text(_carryOver.map((t) => t.text).join(', '),
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: FilledButton.tonal(
                            onPressed: _moveCarryOver,
                            child: const Text('Move here'),
                          ),
                        ),
                      ),

                    // ---- Tasks ----
                    Row(
                      children: [
                        Text('✅ Tasks', style: Theme.of(context).textTheme.titleLarge),
                        const Spacer(),
                        if (total > 0)
                          Text('$done of $total done',
                              style: TextStyle(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                    if (total > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 4),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: done / total,
                            minHeight: 6,
                            color: done == total ? Colors.green : scheme.primary,
                          ),
                        ),
                      ),
                    if (total > 0 && done == total)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text('🎉 All tasks done!', style: TextStyle(color: Colors.green)),
                      ),
                    const SizedBox(height: 4),
                    for (final t in _data.tasks)
                      Dismissible(
                        key: ValueKey(t.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          color: scheme.errorContainer,
                          child: Icon(Icons.delete, color: scheme.onErrorContainer),
                        ),
                        onDismissed: (_) => _delete(t),
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Checkbox(value: t.done, onChanged: (_) => _toggle(t)),
                          title: Text(
                            t.text,
                            style: TextStyle(
                              decoration: t.done ? TextDecoration.lineThrough : null,
                              color: t.done ? scheme.onSurfaceVariant : null,
                            ),
                          ),
                          subtitle: t.time == null
                              ? null
                              : Row(
                                  children: [
                                    Icon(Icons.schedule, size: 14, color: scheme.primary),
                                    const SizedBox(width: 4),
                                    Text(_fmtTime(t.time!)),
                                  ],
                                ),
                          trailing: IconButton(
                            tooltip: 'Important',
                            icon: Icon(t.important ? Icons.star : Icons.star_border,
                                color: t.important ? Colors.amber : scheme.outline),
                            onPressed: () {
                              setState(() {
                                t.important = !t.important;
                                _sortTasks();
                              });
                              _save();
                            },
                          ),
                          onTap: () => _edit(t),
                        ),
                      ),
                    // Add task.
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _newTask,
                            focusNode: _newTaskFocus,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _addTask(),
                            decoration: InputDecoration(
                              hintText: 'Add a task…',
                              prefixIcon: const Icon(Icons.add_task),
                              border: const OutlineInputBorder(),
                              isDense: true,
                              suffixIcon: IconButton(
                                tooltip: 'Set a time',
                                icon: Icon(Icons.schedule,
                                    color: _newTaskTime == null ? null : scheme.primary),
                                onPressed: () async {
                                  final picked = await showTimePicker(
                                    context: context,
                                    initialTime: _newTaskTime ?? TimeOfDay.now(),
                                  );
                                  if (picked != null) setState(() => _newTaskTime = picked);
                                },
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(onPressed: _addTask, icon: const Icon(Icons.add)),
                      ],
                    ),
                    if (_newTaskTime != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, left: 4),
                        child: Text('⏰ ${_newTaskTime!.format(context)}',
                            style: TextStyle(color: scheme.primary)),
                      ),
                    if (total == 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('Tip: tap a task to edit, swipe left to delete, ⭐ for important.',
                            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                      ),

                  ],
                ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _newTask.dispose();
    _newTaskFocus.dispose();
    super.dispose();
  }
}

/// Month view: dots on days with tasks, ✓ when every task was done.
class _MonthCalendar extends StatefulWidget {
  const _MonthCalendar({required this.selected});
  final DateTime selected;

  @override
  State<_MonthCalendar> createState() => _MonthCalendarState();
}

class _MonthCalendarState extends State<_MonthCalendar> {
  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  late DateTime _month = DateTime(widget.selected.year, widget.selected.month);
  Map<int, DayMark> _marks = {};

  @override
  void initState() {
    super.initState();
    _loadMarks();
  }

  Future<void> _loadMarks() async {
    final marks = await DiaryStore.monthMarks(_month);
    if (mounted) setState(() => _marks = marks);
  }

  void _shift(int months) {
    setState(() {
      _month = DateTime(_month.year, _month.month + months);
      _marks = {};
    });
    _loadMarks();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final today = DiaryStore.dateOnly(DateTime.now());
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final leading = DateTime(_month.year, _month.month, 1).weekday - 1; // Monday first

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_left)),
                Expanded(
                  child: Text('${_months[_month.month - 1]} ${_month.year}',
                      textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                ),
                IconButton(onPressed: () => _shift(1), icon: const Icon(Icons.chevron_right)),
              ],
            ),
            Row(
              children: [
                for (final d in ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
                  Expanded(
                    child: Center(
                      child: Text(d, style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.bold)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (var i = 0; i < leading; i++) const SizedBox(),
                for (var day = 1; day <= daysInMonth; day++)
                  Builder(builder: (context) {
                    final date = DateTime(_month.year, _month.month, day);
                    final selected = date == widget.selected;
                    final isToday = date == today;
                    final mark = _marks[day] ?? DayMark.none;
                    return InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.pop(context, date),
                      child: Container(
                        margin: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected ? scheme.primary : null,
                          border: isToday && !selected ? Border.all(color: scheme.primary, width: 2) : null,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('$day',
                                style: TextStyle(
                                  color: selected ? scheme.onPrimary : null,
                                  fontWeight: isToday ? FontWeight.bold : null,
                                )),
                            if (mark == DayMark.allDone)
                              Icon(Icons.check, size: 12, color: selected ? scheme.onPrimary : Colors.green)
                            else if (mark == DayMark.entry)
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: selected ? scheme.onPrimary : scheme.primary,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
