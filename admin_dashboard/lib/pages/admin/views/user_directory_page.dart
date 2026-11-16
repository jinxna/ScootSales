import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../utils/user_directory_view.dart';
import '../../../widgets/dso_filter_controls.dart';
import '../widgets/user_management_team_chart.dart';

class UserDirectoryPage extends StatefulWidget {
  const UserDirectoryPage({
    super.key,
    required this.currentUser,
    this.usersStream,
  });

  final UserProfile currentUser;
  final Stream<List<Map<String, dynamic>>>? usersStream;

  @override
  State<UserDirectoryPage> createState() => _UserDirectoryPageState();
}

class _UserDirectoryPageState extends State<UserDirectoryPage> {
  static const List<(String, String)> _roles = <(String, String)>[
    ('all', 'All'),
    ('admin', 'Admin'),
    ('branch_manager', 'Branch manager'),
    ('supervisor', 'Supervisor'),
    ('salesman', 'Salesman'),
  ];

  late final CmsRepository _repository = CmsRepository();
  final TextEditingController _searchController = TextEditingController();
  String _roleFilter = 'all';
  int _pagesLoaded = 1;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: widget.usersStream ?? _repository.watchCollection('users'),
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
          ) {
            final UserDirectoryView view = UserDirectoryView.from(
              currentUser: widget.currentUser,
              hasData: snapshot.hasData,
              hasError: snapshot.hasError,
              rawRows: snapshot.data ?? <Map<String, dynamic>>[],
            );
            final ScootColors c = ScootColors.of(context);
            final bool showChart =
                widget.currentUser.isAdmin &&
                view.state == UserDirectoryState.ready &&
                !view.showsOwnAccountOnly;
            Widget people(bool beside) => ScootCard(
              title: 'People',
              trailing: view.state == UserDirectoryState.ready
                  ? Text(
                      '${view.scopedRowCount} people',
                      style: ScootType.small.copyWith(color: c.muted),
                    )
                  : null,
              padding: EdgeInsets.zero,
              child: _body(context, view, compactColumns: beside),
            );
            return LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) {
                if (!showChart || box.maxWidth < 1100) {
                  return ListView(
                    padding: EdgeInsets.zero,
                    children: <Widget>[people(false)],
                  );
                }
                return ListView(
                  padding: EdgeInsets.zero,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(child: people(true)),
                        const SizedBox(width: 18),
                        SizedBox(
                          width: 360,
                          child: ScootCard(
                            title: 'Team chart',
                            padding: EdgeInsets.zero,
                            child: SizedBox(
                              height: 560,
                              child: UserManagementTeamChart(users: view.rows),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            );
          },
    );
  }

  Widget _body(
    BuildContext context,
    UserDirectoryView view, {
    bool compactColumns = false,
  }) {
    if (view.state == UserDirectoryState.loading) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: ScootLoadingState(
          onRetry: () => setState(() {}),
          semanticLabel: 'Loading the user directory',
          skeleton: Column(
            children: <Widget>[
              for (int i = 0; i < 6; i++)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: ScootSkeleton(height: 14),
                ),
            ],
          ),
        ),
      );
    }
    if (view.state == UserDirectoryState.error) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: ScootErrorState(
          title: 'Could not load user profiles',
          message:
              'The read failed or was denied. The list is not shown empty on '
              'purpose. Try again.',
          onRetry: () => setState(() {}),
        ),
      );
    }

    final List<Map<String, dynamic>> scoped = view.rows;
    final String query = _searchController.text.trim().toLowerCase();
    final List<Map<String, dynamic>> matches = scoped
        .where((Map<String, dynamic> user) {
          if (_roleFilter != 'all' && _readRole(user) != _roleFilter) {
            return false;
          }
          if (query.isEmpty) return true;
          return <String>[
            _readText(user['name']),
            _readText(user['email']),
            _readText(user['employeeCode'] ?? user['userId']),
            _readText(user['branchId'] ?? user['branch_id']),
            _readText(user['supervisorId'] ?? user['supervisor_id']),
          ].join(' ').toLowerCase().contains(query);
        })
        .toList(growable: false);
    final List<Map<String, dynamic>> rows =
        view.showsOwnAccountOnly && view.ownAccountRow != null
        ? <Map<String, dynamic>>[view.ownAccountRow!]
        : matches;
    int countOf(String role) => role == 'all'
        ? scoped.length
        : scoped.where((Map<String, dynamic> u) => _readRole(u) == role).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (view.showsOwnAccountOnly)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: ScootNotice(
              tone: ScootTone.warning,
              icon: ScootIcons.warning,
              message:
                  'The directory returned no other profiles for this account, '
                  'so only your own profile is shown. If you expected other '
                  'users, the read was scoped or denied. Check Role Assignment '
                  'and the account scope.',
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: DsoFilterMetrics.gap,
            runSpacing: DsoFilterMetrics.gap,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              DsoFilterSearchField(
                controller: _searchController,
                width: 360,
                hintText: 'Search name, email, or code',
                onChanged: (_) => setState(() => _pagesLoaded = 1),
              ),
              for (final (String id, String label) in _roles)
                _RoleChip(
                  label: label,
                  count: countOf(id),
                  selected: _roleFilter == id,
                  onTap: () => setState(() {
                    _roleFilter = id;
                    _pagesLoaded = 1;
                  }),
                ),
            ],
          ),
        ),
        ScootDataTable<Map<String, dynamic>>(
          phase: ScootLoadPhase.ready,
          onRetry: () => setState(() {}),
          rows: rows,
          pagesLoaded: _pagesLoaded,
          hasMore: rows.length > ScootPaging.pageSize * _pagesLoaded,
          onLoadMore: () => setState(() => _pagesLoaded += 1),
          countLabel: 'Showing ${rows.length} of ${scoped.length}',
          emptyTitle: 'No people match',
          emptyMessage: 'Change the search or the role filter.',
          rowLabel: (Map<String, dynamic> user) =>
              '${_readText(user['name'], fallback: 'Unknown user')}, '
              '${_roleLabel(_readRole(user))}',
          columns: <ScootTableColumn<Map<String, dynamic>>>[
            ScootTableColumn<Map<String, dynamic>>(
              label: 'Name',
              flex: 3,
              cell: (BuildContext context, Map<String, dynamic> user) =>
                  _NameCell(
                    name: _readText(user['name'], fallback: 'Unknown user'),
                    email: _readText(user['email'], fallback: 'No email'),
                  ),
            ),
            ScootTableColumn<Map<String, dynamic>>(
              label: 'Code',
              width: 120,
              cell: (BuildContext context, Map<String, dynamic> user) => Text(
                _readText(
                  user['employeeCode'] ?? user['userId'],
                  fallback: '—',
                ),
                style: ScootType.mono,
              ),
            ),
            ScootTableColumn<Map<String, dynamic>>(
              label: 'Role',
              width: 150,
              cell: (BuildContext context, Map<String, dynamic> user) =>
                  ScootBadge(
                    label: _roleLabel(_readRole(user)),
                    tone: _readRole(user) == 'admin'
                        ? ScootTone.info
                        : ScootTone.neutral,
                  ),
            ),
            if (!compactColumns)
              ScootTableColumn<Map<String, dynamic>>(
                label: 'Branch',
                flex: 2,
                cell: (BuildContext context, Map<String, dynamic> user) => Text(
                  _readText(
                    user['branchId'] ?? user['branch_id'],
                    fallback: 'Not linked',
                  ),
                ),
              ),
            ScootTableColumn<Map<String, dynamic>>(
              label: 'Reports to',
              flex: 2,
              cell: (BuildContext context, Map<String, dynamic> user) => Text(
                _readRole(user) == 'salesman'
                    ? _readText(
                        user['supervisorId'] ?? user['supervisor_id'],
                        fallback: 'Not linked',
                      )
                    : 'None',
              ),
            ),
            if (!compactColumns)
              ScootTableColumn<Map<String, dynamic>>(
                label: 'Contact',
                flex: 2,
                cell: (BuildContext context, Map<String, dynamic> user) => Text(
                  _readText(
                    user['contactNumber'] ?? user['contact_number'],
                    fallback: 'Not provided',
                  ),
                ),
              ),
            ScootTableColumn<Map<String, dynamic>>(
              label: 'Status',
              width: 110,
              cell: (BuildContext context, Map<String, dynamic> user) =>
                  _statusBadge(_statusOf(user)),
            ),
          ],
        ),
      ],
    );
  }

  String _statusOf(Map<String, dynamic> user) =>
      _readText(user['invitationState']).toLowerCase() == 'pending'
      ? 'invited'
      : _readText(user['status'], fallback: 'active');

  String _readRole(Map<String, dynamic> user) =>
      _readText(user['role'] ?? user['user_group'], fallback: 'unknown');

  String _roleLabel(String role) {
    switch (role) {
      case 'admin':
        return 'Admin';
      case 'branch_manager':
        return 'Branch manager';
      case 'supervisor':
        return 'Supervisor';
      case 'salesman':
        return 'Salesman';
      default:
        return role;
    }
  }

  String _readText(Object? value, {String fallback = ''}) {
    final String text = '$value'.trim();
    if (text.isEmpty || text == 'null') return fallback;
    return text;
  }
}

Widget _statusBadge(String value) {
  switch (value.toLowerCase()) {
    case 'active':
      return const ScootBadge(label: 'Active', tone: ScootTone.success);
    case 'invited':
      return const ScootBadge(
        label: 'Invited',
        tone: ScootTone.info,
        icon: ScootIcons.inbox,
      );
    default:
      return const ScootBadge(label: 'Suspended', tone: ScootTone.warning);
  }
}

class _NameCell extends StatelessWidget {
  const _NameCell({required this.name, required this.email});

  final String name;
  final String email;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Row(
      children: <Widget>[
        CircleAvatar(
          radius: 14,
          backgroundColor: c.brandTint,
          child: Text(
            name.trim().isEmpty ? '?' : name.trim().characters.first,
            style: ScootType.smallStrong.copyWith(color: c.brandText),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ScootType.bodyStrong.copyWith(color: c.ink),
              ),
              Text(
                email,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ScootType.small.copyWith(color: c.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '$label $count',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        borderRadius: ScootRadius.pillAll,
        onTap: onTap,
        child: Container(
          height: DsoFilterMetrics.height,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected ? c.ink : c.card,
            border: Border.all(color: selected ? c.ink : c.line),
            borderRadius: ScootRadius.pillAll,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '$label  $count',
                style: ScootType.smallStrong.copyWith(
                  color: selected ? c.card : c.text2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
