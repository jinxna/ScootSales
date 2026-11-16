library;

enum PermissionAction {
  view('view', 'View'),
  create('create', 'Create'),
  edit('edit', 'Edit'),
  delete('delete', 'Delete');

  const PermissionAction(this.wire, this.label);

  final String wire;
  final String label;
}

class PermissionModule {
  const PermissionModule({
    required this.id,
    required this.label,
    required this.pageKeys,
  });

  final String id;
  final String label;

  final List<String> pageKeys;
}

class PermissionModuleRegistry {
  const PermissionModuleRegistry._();

  static const String roleAdmin = 'admin';
  static const String roleDeveloper = 'developer';
  static const String roleBranchManager = 'branch_manager';
  static const String roleSupervisor = 'supervisor';

  static const List<String> matrixRoles = <String>[
    roleAdmin,
    roleBranchManager,
    roleSupervisor,
  ];

  static const List<PermissionModule> modules = <PermissionModule>[
    PermissionModule(
      id: 'products',
      label: 'Products',
      pageKeys: <String>['product'],
    ),
    PermissionModule(
      id: 'departments',
      label: 'Departments',
      pageKeys: <String>['department'],
    ),
    PermissionModule(
      id: 'categories',
      label: 'Categories',
      pageKeys: <String>['category'],
    ),
    PermissionModule(
      id: 'retailer_scoresheets',
      label: 'Retailer Score Sheets',
      pageKeys: <String>['retailer_scoresheets'],
    ),
    PermissionModule(
      id: 'department_pic',
      label: 'Retailer Department PIC',
      pageKeys: <String>['department_pic'],
    ),
    PermissionModule(
      id: 'website_pages',
      label: 'Website Content',
      pageKeys: <String>[
        'website_pages',
        'website_title',
        'website_logo',
        'terms',
        'banner',
        'tax',
      ],
    ),
  ];

  static PermissionModule? byId(String id) {
    for (final PermissionModule module in modules) {
      if (module.id == id) return module;
    }
    return null;
  }

  static PermissionModule? forPageKey(String pageKey) {
    for (final PermissionModule module in modules) {
      if (module.pageKeys.contains(pageKey)) return module;
    }
    return null;
  }

  static const List<String> delegatedRoles = <String>[
    roleBranchManager,
    roleSupervisor,
  ];

  static const List<String> teamScopedModuleIds = <String>[
    'retailer_scoresheets',
    'department_pic',
  ];

  static const List<String> priceModuleIds = <String>[
    'products',
    'retailer_scoresheets',
  ];

  static const List<PermissionAction> writeActions = <PermissionAction>[
    PermissionAction.create,
    PermissionAction.edit,
    PermissionAction.delete,
  ];

  static const int mirrorShape = 3;

  static const int legacyMirrorShape = 2;

  static const String grantsCollection = 'role_permission_grants';

  static bool isDelegated(String role, String moduleId) =>
      delegatedRoles.contains(role) && byId(moduleId) != null;

  static bool isCellConfigurable(
    String role,
    String moduleId,
    PermissionAction action,
  ) => byId(moduleId) != null && matrixRoles.contains(role);

  static bool baselineAllows(String role, PermissionAction action) =>
      role == roleAdmin ||
      (action == PermissionAction.view && matrixRoles.contains(role));
}

class PermissionPolicy {
  PermissionPolicy._(this._grants, this.revision, this.sourceFromDocument);

  final Map<String, Set<String>> _grants;

  final int revision;

  final bool sourceFromDocument;

  static String cellToken(String moduleId, PermissionAction action) =>
      '$moduleId:${action.wire}';

  static Set<String> _baselineRow(String role) => <String>{
    for (final PermissionModule module in PermissionModuleRegistry.modules)
      for (final PermissionAction action in PermissionAction.values)
        if (PermissionModuleRegistry.isCellConfigurable(
              role,
              module.id,
              action,
            ) &&
            PermissionModuleRegistry.baselineAllows(role, action))
          cellToken(module.id, action),
  };

  factory PermissionPolicy.baseline() => PermissionPolicy._(
    <String, Set<String>>{
      for (final String role in PermissionModuleRegistry.matrixRoles)
        role: _baselineRow(role),
    },
    0,
    false,
  );

  factory PermissionPolicy.forActorRole(
    String role,
    Map<String, dynamic>? grantsDocument,
  ) {
    final PermissionPolicy base = PermissionPolicy.baseline();
    final Object? listed = grantsDocument?['grants'];
    if (listed is! List) return base;
    final Map<String, Set<String>> grants = base._copyGrants();
    final Set<String> eligible = _allEligibleTokens(role);
    final Object? shape = grantsDocument?['shape'];
    final bool fullRow = shape == PermissionModuleRegistry.mirrorShape;
    final bool legacyWithView =
        shape == PermissionModuleRegistry.legacyMirrorShape;
    grants[role] = <String>{
      if (!fullRow)
        for (final String token in grants[role] ?? const <String>{})
          if (!legacyWithView || !_isTeamScopedToken(token)) token,
      for (final Object? entry in listed)
        if (entry is String &&
            eligible.contains(entry.trim()) &&
            (fullRow || _isTeamScopedToken(entry.trim())))
          entry.trim(),
    };
    if (PermissionModuleRegistry.delegatedRoles.contains(role)) {
      grants[role]!.removeWhere(_isWriteWithoutView(grants[role]!));
    }
    final Object? revision = grantsDocument?['revision'];
    return PermissionPolicy._(
      grants,
      revision is num ? revision.toInt() : 0,
      true,
    );
  }

  factory PermissionPolicy.fromDocument(Map<String, dynamic>? data) {
    final PermissionPolicy base = PermissionPolicy.baseline();
    if (data == null) return base;
    final Object? roles = data['roles'];
    if (roles is! Map) return base;
    final Map<String, Set<String>> grants = base._copyGrants();
    bool fromDocument = false;
    for (final String role in PermissionModuleRegistry.matrixRoles) {
      final Object? row = roles[role];
      if (row is! List) continue;
      fromDocument = true;
      final Set<String> eligible = _allEligibleTokens(role);
      grants[role] = <String>{
        for (final Object? entry in row)
          if (entry is String && eligible.contains(entry.trim())) entry.trim(),
      };
      if (PermissionModuleRegistry.delegatedRoles.contains(role)) {
        grants[role]!.removeWhere(_isWriteWithoutView(grants[role]!));
      }
    }
    final int revision = data['revision'] is num
        ? (data['revision'] as num).toInt()
        : 0;
    return PermissionPolicy._(grants, revision, fromDocument);
  }

  static bool Function(String) _isWriteWithoutView(Set<String> row) =>
      (String token) {
        final int split = token.indexOf(':');
        if (split < 0) return false;
        final String moduleId = token.substring(0, split);
        return token.substring(split + 1) != PermissionAction.view.wire &&
            !row.contains(cellToken(moduleId, PermissionAction.view));
      };

  static bool _isTeamScopedToken(String token) => PermissionModuleRegistry
      .teamScopedModuleIds
      .any((String moduleId) => token.startsWith('$moduleId:'));

  static Set<String> _allEligibleTokens(String role) => <String>{
    for (final PermissionModule module in PermissionModuleRegistry.modules)
      for (final PermissionAction action in PermissionAction.values)
        if (PermissionModuleRegistry.isCellConfigurable(
          role,
          module.id,
          action,
        ))
          cellToken(module.id, action),
  };

  Map<String, Set<String>> _copyGrants() => <String, Set<String>>{
    for (final MapEntry<String, Set<String>> entry in _grants.entries)
      entry.key: <String>{...entry.value},
  };

  bool allows(String role, String moduleId, PermissionAction action) {
    final String roleKey = role.trim().toLowerCase();
    if (roleKey == PermissionModuleRegistry.roleDeveloper) return true;
    return _grants[roleKey]?.contains(cellToken(moduleId, action)) ?? false;
  }

  PermissionPolicy withCell(
    String role,
    String moduleId,
    PermissionAction action, {
    required bool allowed,
  }) {
    if (!PermissionModuleRegistry.isCellConfigurable(role, moduleId, action)) {
      throw ArgumentError.value('$role/$moduleId/${action.wire}', 'cell');
    }
    final Map<String, Set<String>> grants = _copyGrants();
    final Set<String> row = grants[role]!;
    allowed
        ? row.add(cellToken(moduleId, action))
        : row.remove(cellToken(moduleId, action));
    return PermissionPolicy._(grants, revision, true);
  }

  PermissionPolicy withRevision(int nextRevision) =>
      PermissionPolicy._(_copyGrants(), nextRevision, true);

  Map<String, bool> diffAgainst(PermissionPolicy other) {
    final Map<String, bool> changes = <String, bool>{};
    for (final String role in PermissionModuleRegistry.matrixRoles) {
      for (final String token in _allEligibleTokens(role)) {
        final bool mine = _grants[role]?.contains(token) ?? false;
        if (mine != (other._grants[role]?.contains(token) ?? false)) {
          changes['$role|${token.replaceFirst(':', '|')}'] = mine;
        }
      }
    }
    return changes;
  }

  List<String> delegatedGrantsFor(String role) {
    final Set<String> row = _grants[role] ?? const <String>{};
    return <String>[
      for (final PermissionModule module in PermissionModuleRegistry.modules)
        for (final PermissionAction action in <PermissionAction>[
          PermissionAction.view,
          ...PermissionModuleRegistry.writeActions,
        ])
          if (row.contains(cellToken(module.id, action)) &&
              (action == PermissionAction.view ||
                  row.contains(cellToken(module.id, PermissionAction.view))))
            cellToken(module.id, action),
    ]..sort();
  }

  Map<String, dynamic> toDocumentPayload({
    required String updatedByUid,
    required String auditDocumentId,
  }) => <String, dynamic>{
    'roles': <String, List<String>>{
      for (final String role in PermissionModuleRegistry.matrixRoles)
        role: (_grants[role]!.toList()..sort()),
    },
    'revision': revision + 1,
    'auditDocumentId': auditDocumentId,
    'updatedByUid': updatedByUid,
  };
}
