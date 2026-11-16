import 'package:flutter/material.dart';

import '../app/workspace_runtime.dart';
import '../services/platform_api_client.dart';

class SigninAccountsReconcile extends StatefulWidget {
  const SigninAccountsReconcile({super.key, this.client});

  final PlatformApiClient? client;

  @override
  State<SigninAccountsReconcile> createState() =>
      _SigninAccountsReconcileState();
}

class _SigninAccountsReconcileState extends State<SigninAccountsReconcile> {
  late final PlatformApiClient _api = widget.client ?? PlatformApiClient();
  AccountReconcile? _result;
  String? _error;
  bool _loading = false;

  Future<void> _check() async {
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
    });
    try {
      final AccountReconcile result = await _api.reconcileAccounts();
      if (!mounted) return;
      setState(() => _result = result);
    } on PlatformApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (WorkspaceRuntime.current == null) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final AccountReconcile? result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Divider(height: 32),
        SizedBox(
          width: double.infinity,
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 8,
            children: <Widget>[
              Text(
                'Sign-in accounts without a profile',
                style: theme.textTheme.titleMedium,
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _check,
                icon: _loading
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.manage_search),
                label: Text(_loading ? 'Checking…' : 'Check sign-in accounts'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Finds sign-in accounts that have no saved profile or access record, '
          'and access records that have no sign-in account. This list only '
          'reports them. It does not change or delete anything.',
          style: theme.textTheme.bodyMedium,
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
        if (result != null) ...<Widget>[
          const SizedBox(height: 12),
          _group(
            context,
            'Sign-in accounts with no profile (${result.authOnly.length})',
            result.authOnly,
            empty: 'Every sign-in account has a profile.',
          ),
          const SizedBox(height: 12),
          _group(
            context,
            'Profiles with no sign-in account (${result.profileOnly.length})',
            result.profileOnly,
            empty: 'Every profile has a sign-in account.',
          ),
        ],
      ],
    );
  }

  Widget _group(
    BuildContext context,
    String title,
    List<AccountReconcileEntry> entries, {
    required String empty,
  }) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: theme.textTheme.titleSmall),
        if (entries.isEmpty)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(empty))
        else
          for (final AccountReconcileEntry entry in entries)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${entry.email.isEmpty ? '(no email)' : entry.email} · '
                'ID ${entry.uid}'
                '${entry.createdAt.isEmpty ? '' : ' · created ${entry.createdAt}'}'
                '${entry.disabled ? ' · disabled' : ''}',
                style: theme.textTheme.bodySmall,
              ),
            ),
      ],
    );
  }
}
