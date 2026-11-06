import 'package:flutter/material.dart';

import 'journal_page.dart';
import 'tasks_page.dart';

/// Diary tab: two separate sections, daily Tasks and the Diary (journal).
class DiaryPage extends StatelessWidget {
  const DiaryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            tabs: [
              Tab(icon: Icon(Icons.checklist), text: 'Tasks'),
              Tab(icon: Icon(Icons.menu_book), text: 'Diary'),
            ],
          ),
          Expanded(
            child: TabBarView(
              physics: NeverScrollableScrollPhysics(), // swipes are used to delete tasks
              children: [TasksPage(), JournalPage()],
            ),
          ),
        ],
      ),
    );
  }
}
