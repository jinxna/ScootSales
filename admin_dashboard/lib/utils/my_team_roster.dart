import 'package:cloud_firestore/cloud_firestore.dart';

import 'order_data_utils.dart';

const int kSupervisorTeamCap = 5;

const Duration _malaysiaOffset = Duration(hours: 8);

DateTime malaysiaWallTime(DateTime instant) =>
    instant.toUtc().add(_malaysiaOffset);

DateTime malaysiaDay(DateTime instant) {
  final DateTime kl = malaysiaWallTime(instant);
  return DateTime.utc(kl.year, kl.month, kl.day);
}

bool isSameMalaysiaDay(DateTime a, DateTime b) =>
    malaysiaDay(a) == malaysiaDay(b);

DateTime malaysiaWeekStart(DateTime instant) {
  final DateTime day = malaysiaDay(instant);
  return day.subtract(Duration(days: day.weekday - 1));
}

DateTime? parseTeamTimestamp(Object? value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is num) {
    final bool millis = value.abs() > 9999999999;
    return DateTime.fromMillisecondsSinceEpoch(
      (millis ? value : value * 1000).round(),
      isUtc: true,
    );
  }
  final String text = value.toString().trim();
  if (text.isEmpty || text.toLowerCase() == 'null') return null;
  return DateTime.tryParse(text);
}

enum TeamMemberStatus { active, suspended, invited, unknown }

enum TeamRouteStatus {
  none('None'),
  draft('Draft'),
  approved('Approved'),
  published('Published');

  const TeamRouteStatus(this.label);
  final String label;
}

class TeamTodayStats {
  const TeamTodayStats({
    this.visitsToday = 0,
    this.ordersToday = 0,
    this.lastOrderAt,
  });

  final int visitsToday;
  final int ordersToday;

  final DateTime? lastOrderAt;

  static const TeamTodayStats empty = TeamTodayStats();
}

class TeamMember {
  const TeamMember({
    required this.code,
    required this.profileFound,
    this.name = '',
    this.employeeCode = '',
    this.uid = '',
    this.phone = '',
    this.email = '',
    this.branchId = '',
    this.status = TeamMemberStatus.unknown,
  });

  final String code;

  final bool profileFound;
  final String name;
  final String employeeCode;
  final String uid;
  final String phone;
  final String email;
  final String branchId;
  final TeamMemberStatus status;

  String get displayName => name.isNotEmpty ? name : code;
}

class TeamMemberCardData {
  const TeamMemberCardData({
    required this.member,
    this.stats = TeamTodayStats.empty,
    this.lastSeenAt,
    this.routeStatus = TeamRouteStatus.none,
  });

  final TeamMember member;
  final TeamTodayStats stats;
  final DateTime? lastSeenAt;
  final TeamRouteStatus routeStatus;
}

String _text(Object? value) => (value ?? '').toString().trim();

String _firstText(Map<String, dynamic> row, List<String> keys) {
  for (final String key in keys) {
    final String text = _text(row[key]);
    if (text.isNotEmpty) return text;
  }
  return '';
}

String userRowCode(Map<String, dynamic> row) => _firstText(row, const <String>[
  'employeeCode',
  'employee_code',
  'staffId',
  'staff_id',
  'userId',
  'user_id',
]);

String _normCode(String code) => code.trim().toUpperCase();

bool _isSalesmanRow(Map<String, dynamic> row) {
  final String role = _text(row['role'] ?? row['user_group']).toLowerCase();
  return role.isEmpty || role == 'salesman';
}

TeamMemberStatus _statusOf(Map<String, dynamic> row) {
  if (_text(row['invitationState']).toLowerCase() == 'pending') {
    return TeamMemberStatus.invited;
  }
  final Object? flag = row['isActive'] ?? row['active'] ?? row['enabled'];
  final String status = _firstText(row, const <String>[
    'status',
    'accountStatus',
    'account_status',
  ]).toLowerCase();
  if (status == 'suspended' ||
      status == 'inactive' ||
      status == 'disabled' ||
      flag == false ||
      flag == 0) {
    return TeamMemberStatus.suspended;
  }
  if (status == 'active' || flag == true || flag == 1) {
    return TeamMemberStatus.active;
  }
  return TeamMemberStatus.unknown;
}

TeamMember _memberFromRow(String code, Map<String, dynamic> row) {
  return TeamMember(
    code: code,
    profileFound: true,
    name: _firstText(row, const <String>['name', 'displayName', 'fullName']),
    employeeCode: userRowCode(row),
    uid: _firstText(row, const <String>['uid']),
    phone: _firstText(row, const <String>[
      'contactNumber',
      'contact_number',
      'phone',
      'phoneNumber',
    ]),
    email: _text(row['email']),
    branchId: _firstText(row, const <String>['branchId', 'branch_id']),
    status: _statusOf(row),
  );
}

List<TeamMember> buildSupervisorRoster({
  required Iterable<String> assignedCodes,
  required Iterable<Map<String, dynamic>> userRows,
}) {
  final Map<String, Map<String, dynamic>> byCode =
      <String, Map<String, dynamic>>{};
  for (final Map<String, dynamic> row in userRows) {
    final String code = _normCode(userRowCode(row));
    if (code.isEmpty) continue;
    final Map<String, dynamic>? existing = byCode[code];
    if (existing == null ||
        (!_isSalesmanRow(existing) && _isSalesmanRow(row))) {
      byCode[code] = row;
    }
  }
  final Set<String> seen = <String>{};
  final List<TeamMember> members = <TeamMember>[];
  for (final String raw in assignedCodes) {
    final String code = raw.trim();
    if (code.isEmpty || !seen.add(_normCode(code))) continue;
    final Map<String, dynamic>? row = byCode[_normCode(code)];
    members.add(
      row == null
          ? TeamMember(code: code, profileFound: false)
          : _memberFromRow(code, row),
    );
  }
  return members;
}

List<TeamMember> buildBranchRoster({
  required Iterable<Map<String, dynamic>> userRows,
}) {
  final Set<String> seen = <String>{};
  final List<TeamMember> members = <TeamMember>[];
  for (final Map<String, dynamic> row in userRows) {
    if (_text(row['role'] ?? row['user_group']).toLowerCase() != 'salesman') {
      continue;
    }
    final String code = userRowCode(row);
    final String identity = code.isNotEmpty
        ? _normCode(code)
        : _text(row['uid'] ?? row['docId']);
    if (identity.isEmpty || !seen.add(identity)) continue;
    members.add(_memberFromRow(code.isNotEmpty ? code : identity, row));
  }
  members.sort(
    (TeamMember a, TeamMember b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
  );
  return members;
}

bool teamRowBelongsTo(Map<String, dynamic> row, TeamMember member) {
  final String code = _normCode(member.code);
  final String ownCode = _normCode(member.employeeCode);
  for (final String key in const <String>[
    'salesmanCode',
    'salesman_code',
    'employeeCode',
    'employee_code',
    'staffId',
    'staff_id',
  ]) {
    final String value = _normCode(_text(row[key]));
    if (value.isEmpty) continue;
    if (value == code || (ownCode.isNotEmpty && value == ownCode)) return true;
  }
  if (member.uid.isNotEmpty) {
    for (final String key in const <String>[
      'salesmanUid',
      'salesman_uid',
      'submittedByUid',
    ]) {
      if (_text(row[key]) == member.uid) return true;
    }
  }
  return false;
}

TeamTodayStats aggregateTodayStats({
  required TeamMember member,
  required Iterable<Map<String, dynamic>> orders,
  required Iterable<Map<String, dynamic>> visits,
  required DateTime now,
}) {
  int orderCount = 0;
  DateTime? lastOrder;
  for (final Map<String, dynamic> row in orders) {
    if (!teamRowBelongsTo(row, member) || !orderCountsAsSale(row)) continue;
    final DateTime? at = parseTeamTimestamp(
      row['submittedAt'] ?? row['createdAt'] ?? row['timestamp'],
    );
    if (at == null || !isSameMalaysiaDay(at, now)) continue;
    orderCount++;
    if (lastOrder == null || at.isAfter(lastOrder)) lastOrder = at;
  }
  int visitCount = 0;
  for (final Map<String, dynamic> row in visits) {
    if (!teamRowBelongsTo(row, member)) continue;
    final DateTime? at = parseTeamTimestamp(
      row['arrivalTime'] ??
          row['arrival_time'] ??
          row['departureTime'] ??
          row['createdAt'] ??
          row['timestamp'],
    );
    if (at == null || !isSameMalaysiaDay(at, now)) continue;
    visitCount++;
  }
  return TeamTodayStats(
    visitsToday: visitCount,
    ordersToday: orderCount,
    lastOrderAt: lastOrder,
  );
}

DateTime? latestLocationAt({
  required TeamMember member,
  required Iterable<Map<String, dynamic>> liveRows,
}) {
  DateTime? latest;
  for (final Map<String, dynamic> row in liveRows) {
    final bool byDocId =
        member.uid.isNotEmpty && _text(row['docId']) == member.uid;
    if (!byDocId && !teamRowBelongsTo(row, member)) continue;
    final DateTime? at = parseTeamTimestamp(
      row['deviceCapturedAt'] ?? row['timestamp'] ?? row['updatedAt'],
    );
    if (at != null && (latest == null || at.isAfter(latest))) latest = at;
  }
  return latest;
}

String formatLastSeen(DateTime? seenAt, DateTime now) {
  if (seenAt == null || !isSameMalaysiaDay(seenAt, now)) {
    return 'No location today';
  }
  final Duration age = now.difference(seenAt);
  if (age.inMinutes < 1) return 'Just now';
  if (age.inMinutes < 60) return '${age.inMinutes} min ago';
  return '${age.inHours} h ago';
}

String formatMalaysiaClock(DateTime instant) {
  final DateTime kl = malaysiaWallTime(instant);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(kl.hour)}:${two(kl.minute)}';
}

TeamRouteStatus routeStatusForWeek({
  required TeamMember member,
  required Iterable<Map<String, dynamic>> plans,
  required DateTime now,
}) {
  final DateTime week = malaysiaWeekStart(now);
  TeamRouteStatus best = TeamRouteStatus.none;
  for (final Map<String, dynamic> row in plans) {
    if (!teamRowBelongsTo(row, member)) continue;
    final DateTime? start = parseTeamTimestamp(row['weekStart']);
    if (start == null || malaysiaWeekStart(start) != week) continue;
    final TeamRouteStatus status = switch (_text(row['status']).toLowerCase()) {
      'published' => TeamRouteStatus.published,
      'approved' => TeamRouteStatus.approved,
      'draft' || '' => TeamRouteStatus.draft,
      _ => TeamRouteStatus.none,
    };
    if (status.index > best.index) best = status;
  }
  return best;
}

List<TeamMemberCardData> assembleTeamCards({
  required List<TeamMember> members,
  required Iterable<Map<String, dynamic>> orders,
  required Iterable<Map<String, dynamic>> visits,
  required Iterable<Map<String, dynamic>> liveRows,
  required Iterable<Map<String, dynamic>> plans,
  required DateTime now,
}) {
  return members
      .map((TeamMember member) {
        if (!member.profileFound) return TeamMemberCardData(member: member);
        return TeamMemberCardData(
          member: member,
          stats: aggregateTodayStats(
            member: member,
            orders: orders,
            visits: visits,
            now: now,
          ),
          lastSeenAt: latestLocationAt(member: member, liveRows: liveRows),
          routeStatus: routeStatusForWeek(
            member: member,
            plans: plans,
            now: now,
          ),
        );
      })
      .toList(growable: false);
}

class TeamTreeSalesman {
  const TeamTreeSalesman({
    required this.code,
    required this.name,
    required this.profileFound,
    this.uid = '',
    this.invited = false,
  });

  final String code;
  final String name;

  final bool profileFound;
  final String uid;
  final bool invited;

  String get label => profileFound
      ? (name.isEmpty ? code : '$name  ·  $code')
      : '$code (no visible profile)';
}

class TeamTreeSupervisor {
  const TeamTreeSupervisor({
    required this.name,
    required this.code,
    required this.salesmen,
    this.uid = '',
    this.branchId = '',
    this.active = true,
  });

  final String name;
  final String code;
  final List<TeamTreeSalesman> salesmen;
  final String uid;
  final String branchId;
  final bool active;

  bool get hasRoom => salesmen.length < kSupervisorTeamCap;

  bool acceptsFrom(TeamTreeSupervisor? from, String branch) =>
      uid != from?.uid && active && hasRoom && branchId.toLowerCase() == branch.toLowerCase();

  String get label => code.isEmpty ? name : '$name  ·  $code';
}

class TeamHierarchy {
  const TeamHierarchy({required this.supervisors, required this.unassigned});

  final List<TeamTreeSupervisor> supervisors;

  final List<TeamTreeSalesman> unassigned;

  int get unassignedCount => unassigned.length;
}

bool _isInvited(Map<String, dynamic> row) =>
    _text(row['invitationState']).toLowerCase() == 'pending';

bool _isActiveRow(Map<String, dynamic> row) =>
    row['isActive'] != false && _text(row['status']).toLowerCase() != 'suspended';

String _roleOf(Map<String, dynamic> row) =>
    _text(row['role'] ?? row['user_group']).toLowerCase();

String _branchOf(Map<String, dynamic> row) =>
    _firstText(row, const <String>['branchId', 'branch_id']);

String _nameOf(Map<String, dynamic> row) =>
    _firstText(row, const <String>['name', 'displayName', 'fullName']);

int _byName(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

TeamHierarchy buildTeamHierarchy({
  required String branchId,
  required Iterable<Map<String, dynamic>> userRows,
}) {
  final String branch = branchId.trim().toLowerCase();
  bool inBranch(Map<String, dynamic> row) =>
      _branchOf(row).toLowerCase() == branch;

  final Map<String, Map<String, dynamic>> salesmenByCode =
      <String, Map<String, dynamic>>{};
  for (final Map<String, dynamic> row in userRows) {
    if (_roleOf(row) != 'salesman' || !inBranch(row)) continue;
    final String code = _normCode(userRowCode(row));
    if (code.isNotEmpty) salesmenByCode.putIfAbsent(code, () => row);
  }

  final List<Map<String, dynamic>> supervisorRows =
      userRows
          .where(
            (Map<String, dynamic> r) =>
                _roleOf(r) == 'supervisor' && inBranch(r),
          )
          .toList()
        ..sort(
          (Map<String, dynamic> a, Map<String, dynamic> b) =>
              _byName(_nameOf(a), _nameOf(b)),
        );

  final Set<String> claimed = <String>{};
  final List<TeamTreeSupervisor> supervisors = <TeamTreeSupervisor>[];
  for (final Map<String, dynamic> sup in supervisorRows) {
    final Object? raw = sup['assignedSalesmanCodes'];
    final List<TeamTreeSalesman> salesmen = <TeamTreeSalesman>[];
    if (raw is Iterable) {
      for (final Object? item in raw) {
        final String code = _text(item);
        if (code.isEmpty || !claimed.add(_normCode(code))) continue;
        final Map<String, dynamic>? row = salesmenByCode[_normCode(code)];
        salesmen.add(
          TeamTreeSalesman(
            code: code,
            name: row == null ? '' : _nameOf(row),
            profileFound: row != null,
            uid: row == null ? '' : _text(row['uid']),
            invited: row != null && _isInvited(row),
          ),
        );
      }
    }
    supervisors.add(
      TeamTreeSupervisor(
        name: _nameOf(sup).isEmpty ? _text(sup['email']) : _nameOf(sup),
        code: userRowCode(sup),
        salesmen: salesmen,
        uid: _text(sup['uid']),
        branchId: _branchOf(sup),
        active: _isActiveRow(sup),
      ),
    );
  }
  final List<TeamTreeSalesman> unassigned =
      salesmenByCode.entries
          .where(
            (MapEntry<String, Map<String, dynamic>> entry) =>
                !claimed.contains(entry.key),
          )
          .map(
            (MapEntry<String, Map<String, dynamic>> entry) => TeamTreeSalesman(
              code: userRowCode(entry.value),
              name: _nameOf(entry.value),
              profileFound: true,
              uid: _text(entry.value['uid']),
              invited: _isInvited(entry.value),
            ),
          )
          .toList()
        ..sort(
          (TeamTreeSalesman a, TeamTreeSalesman b) => _byName(a.name, b.name),
        );
  return TeamHierarchy(supervisors: supervisors, unassigned: unassigned);
}

class TeamChartBranch {
  const TeamChartBranch({
    required this.branchId,
    required this.name,
    required this.managers,
    required this.hierarchy,
  });

  final String branchId;
  final String name;
  final List<String> managers;
  final TeamHierarchy hierarchy;
}

List<TeamChartBranch> buildCompanyTeamChart({
  required Iterable<Map<String, dynamic>> userRows,
  Map<String, String> branchNames = const <String, String>{},
}) {
  final Map<String, String> branchIds = <String, String>{};
  for (final Map<String, dynamic> row in userRows) {
    final String role = _roleOf(row);
    final String branch = _branchOf(row);
    if (branch.isEmpty ||
        !const <String>{
          'salesman',
          'supervisor',
          'branch_manager',
        }.contains(role)) {
      continue;
    }
    branchIds.putIfAbsent(branch.toLowerCase(), () => branch);
  }
  final List<TeamChartBranch> branches =
      branchIds.values.map((String id) {
        final List<String> managers =
            userRows
                .where(
                  (Map<String, dynamic> row) =>
                      _roleOf(row) == 'branch_manager' &&
                      _branchOf(row).toLowerCase() == id.toLowerCase(),
                )
                .map(
                  (Map<String, dynamic> row) =>
                      _nameOf(row).isEmpty ? _text(row['email']) : _nameOf(row),
                )
                .toList()
              ..sort(_byName);
        final String name = (branchNames[id] ?? '').trim();
        return TeamChartBranch(
          branchId: id,
          name: name.isEmpty ? id : name,
          managers: managers,
          hierarchy: buildTeamHierarchy(branchId: id, userRows: userRows),
        );
      }).toList()..sort(
        (TeamChartBranch a, TeamChartBranch b) => _byName(a.name, b.name),
      );
  return branches;
}

String myTeamHeaderText({required bool supervisor, required int count}) {
  if (supervisor) {
    return 'My Team · $count of $kSupervisorTeamCap salespeople';
  }
  return 'Branch team · $count ${count == 1 ? 'salesperson' : 'salespeople'}';
}
