import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../repositories/cms_repository.dart';
import '../../../repositories/user_management_repository.dart';
import '../../../services/platform_api_client.dart';
import '../../../utils/my_team_roster.dart';
import '../../../widgets/team_hierarchy_tree.dart';

class UserManagementTeamChart extends StatefulWidget {
  const UserManagementTeamChart({super.key, required this.users});

  final List<Map<String, dynamic>> users;

  @override
  State<UserManagementTeamChart> createState() =>
      _UserManagementTeamChartState();
}

class _UserManagementTeamChartState extends State<UserManagementTeamChart> {
  final CmsRepository _repository = CmsRepository();
  late final Stream<List<Map<String, dynamic>>> _branches = _repository
      .watchCollection('branches', orderBy: 'branchName');
  bool _moving = false;

  void _toast(String message, {bool isError = false}) {
    if (!mounted) return;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: isError ? TextStyle(color: scheme.onErrorContainer) : null,
          ),
          backgroundColor: isError ? scheme.errorContainer : null,
          duration: Duration(seconds: isError ? 8 : 4),
        ),
      );
  }

  Future<int?> _routesInProgress(String uid) async {
    try {
      final AggregateQuerySnapshot result = await FirebaseFirestore.instance
          .collection('route_plan_progress')
          .where('salesmanUid', isEqualTo: uid)
          .where('status', isEqualTo: 'in_progress')
          .count()
          .get();
      return result.count ?? 0;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _confirm(
    TeamTreeSalesman salesman,
    TeamTreeSupervisor? from,
    TeamTreeSupervisor to,
    int? routes,
  ) async {
    final String who = salesman.name.isEmpty ? salesman.code : salesman.name;
    final String routeText = switch (routes) {
      null => 'Routes in progress could not be checked.',
      0 => 'No routes in progress.',
      1 => '1 route in progress. It stays with $who.',
      _ => '$routes routes in progress. They stay with $who.',
    };
    final bool? answer = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Move $who?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              from == null
                  ? 'From no supervisor to ${to.name}.'
                  : 'From ${from.name} to ${to.name}.',
            ),
            const SizedBox(height: 8),
            Text(routeText),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Move'),
          ),
        ],
      ),
    );
    return answer == true;
  }

  Future<void> _move(
    TeamTreeSalesman salesman,
    TeamTreeSupervisor? from,
    TeamTreeSupervisor to,
  ) async {
    if (_moving) return;
    if (to.uid.isEmpty) {
      _toast(
        'This supervisor has no sign-in account yet, so nobody can be moved '
        'to them.',
        isError: true,
      );
      return;
    }
    setState(() => _moving = true);
    try {
      final int? routes = await _routesInProgress(salesman.uid);
      if (!mounted || !await _confirm(salesman, from, to, routes)) return;
      await PlatformApiClient().moveSalesperson(
        salesman.uid,
        supervisorUid: to.uid,
        idempotencyKey: const Uuid().v4(),
      );
      final String who = salesman.name.isEmpty ? salesman.code : salesman.name;
      _toast('$who now reports to ${to.name}.');
    } on PlatformApiException catch (error) {
      _toast(error.message, isError: true);
    } finally {
      if (mounted) setState(() => _moving = false);
    }
  }

  Future<void> _removeOrphan(
    TeamTreeSalesman orphan,
    TeamTreeSupervisor supervisor,
  ) async {
    if (_moving) return;
    if (supervisor.docId.isEmpty) {
      _toast(
        'This supervisor has no profile record, so the list cannot change.',
        isError: true,
      );
      return;
    }
    final bool? answer = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Remove ${orphan.code} from the team?'),
        content: Text(
          '${orphan.code} has no profile any more. This takes the code off '
          'the team of ${supervisor.name}. No person is removed.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove from team'),
          ),
        ],
      ),
    );
    if (answer != true || !mounted) return;
    setState(() => _moving = true);
    try {
      await UserManagementRepository().removeCodeFromTeam(
        supervisorDocId: supervisor.docId,
        supervisorUid: supervisor.uid,
        salesmanCode: orphan.code,
      );
      _toast('${orphan.code} is no longer on the team of ${supervisor.name}.');
    } on FirebaseException catch (error) {
      _toast(
        error.code == 'permission-denied'
            ? 'You do not have permission to change this team.'
            : 'The team was not changed. Try again.',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _moving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _branches,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
          ) {
            final Map<String, String> names = <String, String>{
              for (final Map<String, dynamic> row
                  in snapshot.data ?? const <Map<String, dynamic>>[])
                (row['branchId'] ?? row['docId'] ?? '').toString().trim():
                    (row['branchName'] ?? row['name'] ?? '').toString(),
            };
            final List<TeamChartBranch> branches = buildCompanyTeamChart(
              userRows: widget.users,
              branchNames: names,
            );
            if (branches.isEmpty) {
              return const Center(child: Text('No branch teams yet.'));
            }
            return SelectionContainer.disabled(
              child: ListView(
                primary: false,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: <Widget>[
                  Text(
                    'Drag a salesperson onto a supervisor, or use the move '
                    'button, to change who they report to.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (_moving) const LinearProgressIndicator(),
                  for (final TeamChartBranch branch in branches) ...<Widget>[
                    const SizedBox(height: 12),
                    TeamHierarchyTree(
                      managerName: '',
                      title: branch.managers.isEmpty
                          ? 'Branch ${branch.name}  ·  no branch manager'
                          : 'Branch ${branch.name}  ·  ${branch.managers.join(', ')}',
                      branchLabel: 'this branch',
                      hierarchy: branch.hierarchy,
                      onMove: _move,
                      onRemoveOrphan: _removeOrphan,
                    ),
                  ],
                ],
              ),
            );
          },
    );
  }
}
