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

/// Home page card: "Login / Register to back up" or "Logged in as (email)".
class BackupCard extends StatelessWidget {
  const BackupCard({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<AccountUser?>(
      valueListenable: ApiClient.instance.user,
      builder: (context, user, _) => Card(
        margin: EdgeInsets.zero,
        color: user == null ? scheme.tertiaryContainer : scheme.secondaryContainer,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Icon(user == null ? Icons.cloud_upload_outlined : Icons.cloud_done_outlined, size: 32),
          title: Text(user == null ? 'Back up your diary & tasks' : 'Cloud backup'),
          subtitle: Text(user == null
              ? 'Login or register to keep them safe, even on a new phone'
              : 'Logged in as ${user.email}'),
          trailing: FilledButton.tonal(
            onPressed: () => AccountPage.open(context),
            child: Text(user == null ? 'Login' : 'Open'),
          ),
          onTap: () => AccountPage.open(context),
        ),
      ),
    );
  }
}
