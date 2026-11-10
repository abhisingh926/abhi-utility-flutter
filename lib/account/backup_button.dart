import 'package:flutter/material.dart';

import 'account_page.dart';
import 'api_client.dart';

/// Small cloud icon for the Diary / Tasks toolbars: opens login or backup.
class BackupButton extends StatelessWidget {
  const BackupButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AccountUser?>(
      valueListenable: ApiClient.instance.user,
      builder: (context, user, _) => IconButton(
        tooltip: user == null ? 'Login to back up' : 'Backup & restore',
        icon: Icon(user == null ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
            color: user == null ? null : Theme.of(context).colorScheme.primary),
        onPressed: () => AccountPage.open(context),
      ),
    );
  }
}
