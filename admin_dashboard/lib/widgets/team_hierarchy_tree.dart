import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../theme/dso_theme.dart';
import '../utils/my_team_roster.dart';

typedef TeamMoveHandler =
    void Function(
      TeamTreeSalesman salesman,
      TeamTreeSupervisor? from,
      TeamTreeSupervisor to,
    );

typedef TeamOrphanHandler =
    void Function(TeamTreeSalesman orphan, TeamTreeSupervisor supervisor);

class TeamHierarchyTree extends StatelessWidget {
  const TeamHierarchyTree({
    super.key,
    required this.managerName,
    required this.hierarchy,
    this.title,
    this.branchLabel = 'your branch',
    this.onMove,
    this.onRemoveOrphan,
  });

  final String managerName;
  final TeamHierarchy hierarchy;
  final String? title;
  final String branchLabel;
  final TeamMoveHandler? onMove;
  final TeamOrphanHandler? onRemoveOrphan;

  String get branchId =>
      hierarchy.supervisors.isEmpty ? '' : hierarchy.supervisors.first.branchId;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final List<TeamTreeSupervisor> sups = hierarchy.supervisors;
    final int unassigned = hierarchy.unassignedCount;
    return Container(
      key: const ValueKey<String>('team-hierarchy-tree'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: dso.card,
        borderRadius: BorderRadius.circular(DsoTokens.rXl),
        border: Border.all(color: dso.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _label(dso, ScootIcons.team, title ?? '$managerName (you)'),
          if (sups.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 6),
              child: Text(
                'No supervisors found in $branchLabel.',
                style: TextStyle(fontSize: 12.5, color: dso.muted),
              ),
            ),
          for (int i = 0; i < sups.length; i++)
            _branch(
              dso,
              last: i == sups.length - 1,
              header: _supervisorHeader(dso, sups[i]),
              children: <Widget>[
                if (sups[i].salesmen.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      'No salespeople assigned.',
                      style: TextStyle(fontSize: 12.5, color: dso.muted),
                    ),
                  ),
                for (int j = 0; j < sups[i].salesmen.length; j++)
                  _branch(
                    dso,
                    last: j == sups[i].salesmen.length - 1,
                    header: _salesman(dso, sups[i].salesmen[j], sups[i]),
                    children: const <Widget>[],
                  ),
              ],
            ),
          if (unassigned > 0) ...<Widget>[
            const SizedBox(height: 10),
            Container(
              key: const ValueKey<String>('team-hierarchy-unassigned'),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: dso.warningSoft,
                borderRadius: BorderRadius.circular(DsoTokens.rMd),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        ScootIcons.warning,
                        size: 16,
                        color: dso.warningText,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          unassigned == 1
                              ? '1 salesperson in $branchLabel has no supervisor.'
                              : '$unassigned salespeople in $branchLabel have no supervisor.',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: dso.warningText,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (onMove != null)
                    for (final TeamTreeSalesman s in hierarchy.unassigned)
                      Padding(
                        padding: const EdgeInsets.only(left: 24),
                        child: _salesman(dso, s, null),
                      ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _supervisorHeader(DsoColors dso, TeamTreeSupervisor sup) {
    final TeamMoveHandler? move = onMove;
    if (move == null) {
      return _label(dso, ScootIcons.person, sup.label);
    }
    return DragTarget<_Dragged>(
      onWillAcceptWithDetails: (DragTargetDetails<_Dragged> details) =>
          sup.acceptsFrom(details.data.from, details.data.branchId),
      onAcceptWithDetails: (DragTargetDetails<_Dragged> details) =>
          move(details.data.salesman, details.data.from, sup),
      builder:
          (
            BuildContext context,
            List<_Dragged?> candidates,
            List<dynamic> rejected,
          ) {
            return Semantics(
              container: true,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  color: candidates.isNotEmpty ? dso.successSoft : null,
                  borderRadius: BorderRadius.circular(DsoTokens.rMd),
                  border: Border.all(
                    color: candidates.isNotEmpty
                        ? dso.accentText
                        : Colors.transparent,
                  ),
                ),
                child: _label(
                  dso,
                  ScootIcons.person,
                  '${sup.label}  ·  ${sup.salesmen.length} of $kSupervisorTeamCap',
                ),
              ),
            );
          },
    );
  }

  Widget _salesman(
    DsoColors dso,
    TeamTreeSalesman s,
    TeamTreeSupervisor? from,
  ) {
    final Widget text = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text(
        s.label,
        style: TextStyle(
          fontSize: 12.5,
          color: s.profileFound ? dso.body : dso.warningText,
        ),
      ),
    );
    final TeamOrphanHandler? removeOrphan = onRemoveOrphan;
    if (!s.profileFound && from != null && removeOrphan != null) {
      return Row(
        children: <Widget>[
          Flexible(child: text),
          TextButton(
            onPressed: () => removeOrphan(s, from),
            child: const Text('Remove from team'),
          ),
        ],
      );
    }
    final TeamMoveHandler? move = onMove;
    if (move == null || s.uid.isEmpty || s.invited) return text;
    final String who = s.name.isEmpty ? s.code : s.name;
    final List<TeamTreeSupervisor> targets = hierarchy.supervisors
        .where((TeamTreeSupervisor sup) => sup.acceptsFrom(from, branchId))
        .toList(growable: false);
    return Row(
      children: <Widget>[
        Flexible(
          child: Draggable<_Dragged>(
            data: _Dragged(s, from, branchId),
            feedback: Material(
              elevation: 4,
              color: dso.card,
              borderRadius: BorderRadius.circular(DsoTokens.rMd),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Text(s.label, style: TextStyle(color: dso.ink)),
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.4, child: text),
            child: Semantics(
              container: true,
              child: MouseRegion(cursor: SystemMouseCursors.grab, child: text),
            ),
          ),
        ),
        PopupMenuButton<TeamTreeSupervisor>(
          tooltip: 'Move $who to...',
          enabled: targets.isNotEmpty,
          icon: Icon(ScootIcons.roleChanged, size: 18, color: dso.muted),
          onSelected: (TeamTreeSupervisor to) => move(s, from, to),
          itemBuilder: (BuildContext context) =>
              <PopupMenuEntry<TeamTreeSupervisor>>[
                for (final TeamTreeSupervisor sup in targets)
                  PopupMenuItem<TeamTreeSupervisor>(
                    value: sup,
                    child: Text(
                      '${sup.label} (${sup.salesmen.length} of $kSupervisorTeamCap)',
                    ),
                  ),
              ],
        ),
      ],
    );
  }

  Widget _label(DsoColors dso, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 16, color: dso.accentText),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: dso.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _branch(
    DsoColors dso, {
    required bool last,
    required Widget header,
    required List<Widget> children,
  }) {
    final Color line = dso.hairline;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(width: 8),
          SizedBox(
            width: 18,
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: last ? null : 0,
                  height: last ? 16 : null,
                  child: Container(width: 1.5, color: line),
                ),
                Positioned(
                  left: 0,
                  top: 15,
                  width: 16,
                  child: Container(height: 1.5, color: line),
                ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[header, ...children],
            ),
          ),
        ],
      ),
    );
  }
}

class _Dragged {
  const _Dragged(this.salesman, this.from, this.branchId);

  final TeamTreeSalesman salesman;
  final TeamTreeSupervisor? from;
  final String branchId;
}
