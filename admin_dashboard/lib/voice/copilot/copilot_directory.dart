library;

import '../../models/user_profile.dart';
import '../../utils/my_team_roster.dart';
import '../../utils/order_data_utils.dart' show isDemoRow;
import '../../utils/retailer_form_utils.dart'
    show normaliseRetailerDisplayStatus;
import 'copilot_entity_resolver.dart';

const Duration kScoutDirectoryReuse = Duration(minutes: 5);

class ScoutShop {
  const ScoutShop({required this.id, required this.name, required this.hidden});
  final String id;
  final String name;
  final bool hidden;
}

class ScoutTeam {
  const ScoutTeam({required this.supervisor, required this.members});
  final EntityRef supervisor;
  final List<TeamMember> members;
}

class ScoutDirectory {
  const ScoutDirectory({
    required this.people,
    required this.teams,
    required this.shopsByKey,
    required this.readAt,
  });

  bool get shopsRead => shopsByKey != null;

  final List<EntityRef> people;
  final List<ScoutTeam> teams;
  final Map<String, List<ScoutShop>>? shopsByKey;
  final DateTime readAt;

  List<EntityRef> get supervisors => <EntityRef>[
    for (final ScoutTeam team in teams) team.supervisor,
  ];

  List<ScoutShop> shopsOf(EntityRef person) {
    final Map<String, ScoutShop> found = <String, ScoutShop>{};
    for (final String key in personKeys(person)) {
      for (final ScoutShop shop in shopsByKey?[key] ?? const <ScoutShop>[]) {
        found.putIfAbsent(shop.id, () => shop);
      }
    }
    return found.values.toList()..sort((ScoutShop a, ScoutShop b) {
      if (a.hidden != b.hidden) return a.hidden ? 1 : -1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  List<ScoutTeam> teamsWith(EntityRef person) {
    final Set<String> keys = personKeys(person);
    return <ScoutTeam>[
      for (final ScoutTeam team in teams)
        if (team.members.any(
          (TeamMember m) => keys.contains(m.code.trim().toLowerCase()),
        ))
          team,
    ];
  }
}

Set<String> personKeys(EntityRef person) => <String>{
  if (person.id.trim().isNotEmpty) person.id.trim().toLowerCase(),
  if (person.code.trim().isNotEmpty) person.code.trim().toLowerCase(),
  ...person.orderKeys,
};

bool userRowInViewerScope(UserProfile viewer, Map<String, dynamic> row) {
  if (viewer.isAdmin || viewer.isDeveloper) return true;
  if (viewer.isBranchManager) {
    final String branch = viewer.branchId.trim().toLowerCase();
    return branch.isNotEmpty &&
        '${row['branchId'] ?? ''}'.trim().toLowerCase() == branch;
  }
  final String code = '${row['employeeCode'] ?? row['userId'] ?? ''}'
      .trim()
      .toLowerCase();
  return code.isNotEmpty &&
      viewer.assignedSalesmanCodes.any(
        (String assigned) => assigned.trim().toLowerCase() == code,
      );
}

String _text(Object? value) {
  final String text = '${value ?? ''}'.trim();
  return text.toLowerCase() == 'null' ? '' : text;
}

EntityRef salespersonRef(Map<String, dynamic> row) {
  final String uid = _text(row['uid'] ?? row['userUid']);
  final String code = _text(row['employeeCode'] ?? row['userId']);
  final String staff = _text(row['staffId']);
  final String name = _text(row['name']).isEmpty
      ? _text(row['email'])
      : _text(row['name']);
  return EntityRef(
    kind: EntityKind.salesperson,
    id: uid.isEmpty ? _text(row['docId']) : uid,
    name: name,
    code: code,
    orderKeys: <String>{
      for (final String key in <String>[uid, code, staff])
        if (key.isNotEmpty) key.toLowerCase(),
    },
  );
}

List<String> _codes(Object? value) => value is Iterable
    ? <String>[
        for (final Object? code in value)
          if (_text(code).isNotEmpty) _text(code),
      ]
    : const <String>[];

const List<String> _shopAssignmentFields = <String>[
  'assignedSalesmanId',
  'assignedSalesmanUid',
  'assignedSalesmanCode',
];

ScoutDirectory buildScoutDirectory({
  required UserProfile viewer,
  required List<Map<String, dynamic>> users,
  required List<Map<String, dynamic>>? retailers,
  required DateTime readAt,
}) {
  final List<Map<String, dynamic>> live = <Map<String, dynamic>>[
    for (final Map<String, dynamic> row in users)
      if (!isDemoRow(row)) row,
  ];
  final List<EntityRef> people = <EntityRef>[
    for (final Map<String, dynamic> row in live)
      if (UserProfile.isSalesmanRole(row['role']) &&
          userRowInViewerScope(viewer, row))
        salespersonRef(row),
  ];
  final List<ScoutTeam> teams = viewer.isSupervisor
      ? <ScoutTeam>[
          ScoutTeam(
            supervisor: EntityRef(
              kind: EntityKind.salesperson,
              id: (viewer.uid ?? '').isEmpty ? viewer.docId : viewer.uid!,
              name: viewer.name.trim().isEmpty ? viewer.email : viewer.name,
              code: viewer.employeeCode,
            ),
            members: buildSupervisorRoster(
              assignedCodes: viewer.assignedSalesmanCodes,
              userRows: live,
            ),
          ),
        ]
      : <ScoutTeam>[
          for (final Map<String, dynamic> row in live)
            if (UserProfile.canonicalRole(row['role']) ==
                    UserProfile.roleSupervisor &&
                userRowInViewerScope(viewer, row))
              ScoutTeam(
                supervisor: salespersonRef(row),
                members: buildSupervisorRoster(
                  assignedCodes: _codes(row['assignedSalesmanCodes']),
                  userRows: live,
                ),
              ),
        ];
  final Map<String, List<ScoutShop>>? shops = retailers == null
      ? null
      : <String, List<ScoutShop>>{};
  for (final Map<String, dynamic> row in retailers ?? const []) {
    if (isDemoRow(row)) continue;
    final String id = _text(row['docId'] ?? row['retailerId']);
    final String name = _text(row['retailerName'] ?? row['name']);
    if (id.isEmpty || name.isEmpty) continue;
    final ScoutShop shop = ScoutShop(
      id: id,
      name: name,
      hidden:
          normaliseRetailerDisplayStatus(
            row['status'],
            visible: row['visible'],
          ) ==
          'Hide',
    );
    final Set<String> keys = <String>{
      for (final String field in _shopAssignmentFields)
        if (_text(row[field]).isNotEmpty) _text(row[field]).toLowerCase(),
    };
    for (final String key in keys) {
      (shops![key] ??= <ScoutShop>[]).add(shop);
    }
  }
  return ScoutDirectory(
    people: people,
    teams: teams,
    shopsByKey: shops,
    readAt: readAt,
  );
}

class ScoutDirectoryReader {
  ScoutDirectoryReader(this._load, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final Future<ScoutDirectory> Function() _load;
  final DateTime Function() _clock;
  ScoutDirectory? _last;

  Future<ScoutDirectory> read() async {
    final ScoutDirectory? last = _last;
    if (last != null &&
        _clock().difference(last.readAt) < kScoutDirectoryReuse) {
      return last;
    }
    return _last = await _load();
  }
}

const Set<String> _notNameWords = <String>{
  'a',
  'an',
  'the',
  'what',
  'which',
  'who',
  'whom',
  'whose',
  'are',
  'is',
  'was',
  'were',
  'that',
  'this',
  'those',
  'these',
  'does',
  'do',
  'did',
  'with',
  'to',
  'of',
  'for',
  'by',
  'in',
  'on',
  'at',
  'from',
  'me',
  'my',
  'our',
  'his',
  'her',
  'their',
  'he',
  'she',
  'they',
  'him',
  'them',
  'i',
  'we',
  'us',
  'you',
  'can',
  'could',
  'please',
  'tell',
  'show',
  'list',
  'give',
  'all',
  'any',
  'has',
  'have',
  'retailer',
  'retailers',
  'shop',
  'shops',
  'store',
  'stores',
  'outlet',
  'outlets',
  'customer',
  'customers',
  'kedai',
  'cover',
  'covers',
  'covered',
  'covering',
  'connect',
  'connects',
  'connected',
  'associated',
  'assigned',
  'handle',
  'handles',
  'handled',
  'serve',
  'serves',
  'served',
  'under',
  'belong',
  'belongs',
  'belonging',
  'team',
  'report',
  'reports',
  'reporting',
  'supervisor',
  'supervises',
  'works',
  'work',
  'people',
  'salesperson',
  'salespeople',
  'salesman',
  'salesmen',
  'rep',
  'reps',
  'member',
  'members',
  'and',
  'or',
  'now',
  'currently',
  'right',
};

List<String> nameWords(String text) => <String>[
  for (final String raw in text.split(RegExp(r'\s+')))
    if (raw.replaceFirst(RegExp(r"'s$"), '').isNotEmpty &&
        !_notNameWords.contains(raw.replaceFirst(RegExp(r"'s$"), '')))
      raw.replaceFirst(RegExp(r"'s$"), ''),
];

Resolution spotEntity(List<String> words, Iterable<EntityRef> pool) {
  final List<EntityRef> candidates = pool.toList(growable: false);
  for (int size = words.length < 3 ? words.length : 3; size >= 1; size--) {
    final Map<String, EntityRef> found = <String, EntityRef>{};
    List<EntityRef>? many;
    for (int i = 0; i + size <= words.length; i++) {
      final Resolution r = resolveEntity(
        words.sublist(i, i + size).join(' '),
        candidates,
      );
      if (r is One) found['${r.entity.id}|${r.entity.code}'] = r.entity;
      if (r is Many) many ??= r.entities;
    }
    if (found.length == 1) return One(found.values.single);
    if (found.length > 1) return Many(found.values.take(5).toList());
    if (many != null) return Many(many);
  }
  return const None();
}
