import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../models/user_profile.dart';
import '../repositories/account_repair_repository.dart';
import '../utils/account_repair_analysis.dart';
import '../utils/user_facing_error.dart';
import 'confirm_destructive_dialog.dart';
import 'signin_accounts_reconcile.dart';

class RepairAccountsCheck extends StatefulWidget {
  const RepairAccountsCheck({
    super.key,
    required this.currentUser,
    this.repository,
  });

  final UserProfile currentUser;
  final AccountRepairRepository? repository;

  @override
  State<RepairAccountsCheck> createState() => _RepairAccountsCheckState();
}

class _RepairAccountsCheckState extends State<RepairAccountsCheck> {
  late final AccountRepairRepository _repository =
      widget.repository ?? FirestoreAccountRepairRepository();
  AccountRepairReport? _report;
  String? _errorMessage;
  bool _scanning = false;
  final Set<String> _repairing = <String>{};

  bool get _allowed =>
      widget.currentUser.isActive && widget.currentUser.isAdmin;

  @override
  Widget build(BuildContext context) {
    if (!_allowed) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: <Widget>[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(Icons.manage_accounts_outlined),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'Repair accounts',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  OutlinedButton.icon(
                    onPressed: _scanning ? null : _scan,
                    icon: _scanning
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.manage_search),
                    label: Text(_scanning ? 'Scanning…' : 'Scan accounts'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Scan saved account profiles and access records. No data changes '
              'until you confirm a repair.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 6),
            Text(
              AccountRepairReport.authEnumerationNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_errorMessage != null) ...<Widget>[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            if (_report case final AccountRepairReport report) ...<Widget>[
              const Divider(height: 24),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: SingleChildScrollView(
                  key: const ValueKey<String>('account-repair-findings-scroll'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        report.scanComplete
                            ? 'Scan complete'
                            : 'Scan incomplete',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        'Read ${report.usersScanned} user profiles and '
                        '${report.accessRecordsScanned} access records. '
                        '${report.findings.length} item(s) need review. '
                        'Concurrent changes during pagination may affect the snapshot; '
                        'each proposed repair checks the current records again.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (report.findings.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text(
                            'No supported inconsistencies were found.',
                          ),
                        )
                      else
                        ...report.findings.map(_findingCard),
                    ],
                  ),
                ),
              ),
            ],
            const SigninAccountsReconcile(),
          ],
        ),
      ),
    );
  }

  Widget _findingCard(AccountRepairFinding finding) {
    final String key =
        '${finding.kind.name}:${finding.recordId}:${finding.relatedId}';
    final bool repairing = _repairing.contains(key);
    return Semantics(
      identifier:
          'account-repair-${finding.kind.name}-${finding.recordId}-${finding.relatedId}',
      container: true,
      child: Card(
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                finding.title,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(finding.description),
              const SizedBox(height: 4),
              Text(
                'Profile/access ID: ${finding.recordId}'
                '${finding.relatedId.isEmpty ? '' : ' · Reference: ${finding.relatedId}'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (finding.canRepair) ...<Widget>[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    onPressed: repairing ? null : () => _repair(finding, key),
                    icon: repairing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.build_outlined),
                    label: Text(repairing ? 'Checking…' : 'Confirm repair'),
                  ),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    finding.kind == AccountRepairFindingKind.missingAccess
                        ? 'Invite this person again from the invitations list.'
                        : 'Manual follow-up required. This check will not '
                              'guess or delete an account or profile.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _errorMessage = null;
      _report = null;
    });
    try {
      final AccountRepairReport report = await _repository.scan(
        actor: widget.currentUser,
      );
      if (!mounted) return;
      setState(() => _report = report);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _errorMessage = _safeError(error, action: 'scan accounts'),
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _repair(AccountRepairFinding finding, String key) async {
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Repair this account record?',
      message:
          '${finding.description}\n\nThe current documents will be read '
          'again. The repair stops if the account changed or the inconsistency '
          'cannot be confirmed.',
      confirmLabel: 'Repair',
      cancelLabel: 'Cancel',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _repairing.add(key);
      _errorMessage = null;
    });
    try {
      await _repository.repair(finding, actor: widget.currentUser);
      if (!mounted) return;
      await _scan();
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _errorMessage = _safeError(error, action: 'repair account data'),
      );
    } finally {
      if (mounted) setState(() => _repairing.remove(key));
    }
  }

  String _safeError(Object error, {required String action}) {
    if (error is FirebaseException) {
      return userFacingError(error, action: action);
    }
    return 'Could not $action. Please refresh the scan and try again.';
  }
}
