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
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: (user == null ? scheme.tertiary : Colors.green).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(user == null ? Icons.cloud_upload_outlined : Icons.cloud_done_outlined,
                color: user == null ? scheme.tertiary : Colors.green, size: 22),
          ),
          title: Text(user == null ? 'Back up your diary & tasks' : 'Cloud backup',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(user == null
              ? 'Log in to keep them safe, even on a new phone'
              : 'Logged in as ${user.email}'),
          trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          onTap: () => AccountPage.open(context),
        ),
      ),
    );
  }
}
