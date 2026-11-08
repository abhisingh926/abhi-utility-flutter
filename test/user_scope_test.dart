import 'dart:convert';

import 'package:abhi_utility/account/api_client.dart';
import 'package:abhi_utility/diary/diary_store.dart';
import 'package:abhi_utility/diary/journal_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 11, 9);

  test('diary and tasks are separate per account; old data goes to the first account', () async {
    SharedPreferences.setMockInitialValues({
      // Logged in as account 1, with data written by an older app version.
      'account:refresh': 'r1',
      'account:access': 'a1',
      'account:user': jsonEncode({'id': 1, 'email': 'a@x.com'}),
      'journal_migrated_v1': true,
      'diary:2026-11-09': jsonEncode({'tasks': [{'id': 't1', 'text': 'A task'}]}),
      'journal:e1': jsonEncode({'id': 'e1', 'date': '2026-11-09T10:00:00.000', 'text': 'A secret', 'images': []}),
    });
    final api = ApiClient.instance;
    await api.load();

    // Account 1 sees its (migrated) data.
    expect((await DiaryStore.load(day)).tasks.single.text, 'A task');
    expect((await JournalStore.all()).single.text, 'A secret');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('diary:2026-11-09'), isFalse);
    expect(prefs.containsKey('u1:diary:2026-11-09'), isTrue);

    // Another account logs in on the same phone: sees nothing of account 1.
    api.user.value = AccountUser(id: 2, email: 'b@x.com');
    expect((await DiaryStore.load(day)).tasks, isEmpty);
    expect(await JournalStore.all(), isEmpty);
    expect(await DiaryStore.monthMarks(day), isEmpty);

    // Account 2 writes its own task; account 1's stays untouched.
    await DiaryStore.save(day, DiaryDay(tasks: [DiaryTask(id: 't2', text: 'B task')]));
    expect((await DiaryStore.load(day)).tasks.single.text, 'B task');

    api.user.value = AccountUser(id: 1, email: 'a@x.com');
    expect((await DiaryStore.load(day)).tasks.single.text, 'A task');
    expect((await JournalStore.all()).single.text, 'A secret');
  });
}
