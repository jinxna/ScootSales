import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../app/permission_policy.dart';
import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../utils/cms_permissions.dart';
import '../../../utils/safe_doc_id.dart';
import '../../../utils/user_facing_error.dart';
import '../../../widgets/cms_feedback.dart';
import '../../../theme/dso_theme.dart';
import '../../../widgets/catalogue/catalogue_column.dart';
import '../../../widgets/catalogue/catalogue_drawer.dart';
import '../../../widgets/catalogue/catalogue_issue_count.dart';
import '../../../widgets/catalogue/catalogue_shortcuts.dart';
import '../../../widgets/catalogue/catalogue_states.dart';
import '../../../widgets/catalogue/catalogue_status_pill.dart';
import '../../../widgets/catalogue/catalogue_table.dart';
import '../../../widgets/catalogue/catalogue_toolbar.dart';
import '../../../widgets/catalogue/catalogue_view_state.dart';
import '../../../widgets/catalogue/catalogue_workspace.dart';
import '../widgets/cms_form_widgets.dart';

typedef _Row = Map<String, dynamic>;

class DepartmentCmsPage extends StatefulWidget {
  const DepartmentCmsPage({super.key, this.currentUser});

  final UserProfile? currentUser;

  @override
  State<DepartmentCmsPage> createState() => _DepartmentCmsPageState();
}

class _DepartmentCmsPageState extends State<DepartmentCmsPage> {
  final CmsRepository _repository = CmsRepository();
  final CatalogueViewState<_DepartmentRow> _view =
      CatalogueViewState<_DepartmentRow>();
  final FocusNode _searchFocus = FocusNode();
  final GlobalKey<CatalogueToolbarState<_DepartmentRow>> _toolbarKey =
      GlobalKey<CatalogueToolbarState<_DepartmentRow>>();
  final ValueNotifier<int> _formRevision = ValueNotifier<int>(0);

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _departmentController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _sortController = TextEditingController(
    text: '0',
  );

  late final Stream<List<_Row>> _departmentStream = _repository.watchCollection(
    'departments',
  );
  late final Stream<List<_Row>> _productStream = _repository.watchCollection(
    'products',
  );

  String? _editingId;
  bool _isActive = true;
  bool _drawerOpen = false;
  bool _saving = false;
  String _formSnapshot = '';
  List<String> _visibleIds = <String>[];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => _view.setQuery(_searchController.text));
    _departmentController.addListener(_onFormChanged);
    _codeController.addListener(_onFormChanged);
    _sortController.addListener(_onFormChanged);
  }

  @override
  void dispose() {
    _view.dispose();
    _searchFocus.dispose();
    _formRevision.dispose();
    _searchController.dispose();
    _departmentController.dispose();
    _codeController.dispose();
    _sortController.dispose();
    super.dispose();
  }

  void _onFormChanged() {
    if (_drawerOpen) _formRevision.value++;
  }

  String _formSignature() => <String>[
    _departmentController.text,
    _codeController.text,
    _sortController.text,
    '$_isActive',
  ].join('\u0000');

  bool get _dirty => _drawerOpen && _formSignature() != _formSnapshot;

  bool _can(PermissionAction action) =>
      cmsActionAllowed(widget.currentUser, 'departments', action);

  bool get _canSaveCurrent => _can(
    _editingId == null ? PermissionAction.create : PermissionAction.edit,
  );

  Future<void> _saveDepartment() async {
    if (_saving) return;
    final String departmentName = _departmentController.text.trim();
    if (departmentName.isEmpty) {
      showCmsToast(context, 'Enter the department name.', isError: true);
      return;
    }

    final bool creating = _editingId == null;
    String departmentId = _editingId ?? _cleanDocId(departmentName);
    if (departmentId.isEmpty) {
      departmentId = safeDocId(departmentName, fallbackPrefix: 'department');
    }
    final String departmentCode = _normaliseDepartmentCode(
      _codeController.text,
      departmentName: departmentName,
    );
    final Map<String, dynamic> data = <String, dynamic>{
      'departmentId': departmentId,
      'departmentName': departmentName,
      'name': departmentName,
      'departmentCode': departmentCode,
      'sortOrder': int.tryParse(_sortController.text.trim()) ?? 0,
      'isActive': _isActive,
      'status': _isActive ? 'active' : 'hidden',
    };
    setState(() => _saving = true);
    try {
      if (creating) {
        await _repository.createDocumentIfAbsent(
          collectionName: 'departments',
          docId: departmentId,
          data: <String, dynamic>{
            ...data,
            'createdAt': FieldValue.serverTimestamp(),
          },
          duplicateMessage:
              'a department named "$departmentName" already exists. Open it '
              'from the list to edit it.',
        );
      } else {
        await _repository.upsertDocument(
          collectionName: 'departments',
          docId: departmentId,
          data: data,
        );
      }
      if (!mounted) return;
      showCmsToast(
        context,
        creating ? 'Department created.' : 'Department saved.',
      );
      _closeDrawer();
    } catch (error) {
      if (!mounted) return;
      showCmsToast(
        context,
        userFacingError(error, action: 'save the department'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _fillForm(_DepartmentRow? department) {
    setState(() {
      if (department == null) {
        _resetFields();
      } else {
        final _Row row = department.source!;
        _editingId = _readText(
          row,
          'docId',
          fallbackKeys: <String>['departmentId'],
        );
        _departmentController.text = _readText(
          row,
          'departmentName',
          fallbackKeys: <String>['name'],
        );
        _codeController.text = _normaliseDepartmentCode(
          _readText(row, 'departmentCode'),
          departmentName: _departmentController.text,
        );
        _sortController.text = _readText(row, 'sortOrder', fallback: '0');
        _isActive =
            row['isActive'] != false &&
            _readText(row, 'status').toLowerCase() != 'hidden';
      }
      _drawerOpen = true;
      _formSnapshot = _formSignature();
    });
    _formRevision.value++;
  }

  void _resetFields() {
    _editingId = null;
    _departmentController.clear();
    _codeController.clear();
    _sortController.text = '0';
    _isActive = true;
  }

  void _clearForm() {
    setState(_resetFields);
    _formRevision.value++;
  }

  void _closeDrawer() {
    setState(() {
      _resetFields();
      _drawerOpen = false;
      _formSnapshot = '';
    });
    _formRevision.value++;
  }

  void _openDrawer(_DepartmentRow? department) => closeCatalogueDrawer(
    context,
    dirty: _dirty,
    onClose: () => _fillForm(department),
  );

  void _requestCloseDrawer() =>
      closeCatalogueDrawer(context, dirty: _dirty, onClose: _closeDrawer);

  void _onEscape() {
    if (_toolbarKey.currentState?.closeMenus() ?? false) return;
    if (_drawerOpen) {
      _requestCloseDrawer();
    } else if (_searchController.text.isNotEmpty) {
      _searchController.clear();
    } else {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  void _toggleFilter(String key, String value) {
    final Set<String> next = Set<String>.of(_view.filters[key] ?? <String>{});
    if (!next.add(value)) next.remove(value);
    _view.setFilter(key, next);
  }

  void _clearFilters() {
    _searchController.clear();
    _view.clearFilters();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<_Row>>(
      stream: _departmentStream,
      builder:
          (BuildContext context, AsyncSnapshot<List<_Row>> departmentSnap) {
            return StreamBuilder<List<_Row>>(
              stream: _productStream,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<List<_Row>> productSnap,
                  ) {
                    return ListenableBuilder(
                      listenable: _view,
                      builder: (BuildContext context, Widget? _) =>
                          ValueListenableBuilder<int>(
                            valueListenable: _formRevision,
                            builder: (_, _, _) => _buildWorkspace(
                              context,
                              departmentSnap,
                              productSnap,
                            ),
                          ),
                    );
                  },
            );
          },
    );
  }

  Widget _buildWorkspace(
    BuildContext context,
    AsyncSnapshot<List<_Row>> departmentSnap,
    AsyncSnapshot<List<_Row>> productSnap,
  ) {
    final List<_Row> departments = List<_Row>.of(
      departmentSnap.data ?? <_Row>[],
    )..sort(_compareDepartmentRows);
    final List<_DepartmentRow> allRows = _buildDepartmentRows(
      departments,
      _buildSummaries(productSnap.data ?? <_Row>[]),
      productsAvailable: !productSnap.hasError,
    );
    final List<CatalogueColumn<_DepartmentRow>> columns = _columns();
    final List<_DepartmentRow> rows = _view.apply(
      allRows,
      idOf: (_DepartmentRow row) => row.id,
      searchBlob: _searchBlob,
      filterValue: <String, String Function(_DepartmentRow)>{
        'status': (_DepartmentRow row) =>
            row.isMaster ? (row.isActive ? 'Active' : 'Hidden') : '',
        'source': (_DepartmentRow row) =>
            row.isMaster ? 'Master' : 'From products',
        'usage': (_DepartmentRow row) => row.productCount == null
            ? 'Unavailable'
            : row.productCount! > 0
            ? 'Referenced'
            : 'No products',
      },
      columns: columns,
      defaultSort: _defaultOrder,
      presets: _presets,
    );
    _visibleIds = rows.map((_DepartmentRow row) => row.id).toList();

    final int hiddenCount = allRows
        .where((_DepartmentRow row) => row.isMaster && !row.isActive)
        .length;
    final int inferredCount = allRows
        .where((_DepartmentRow row) => !row.isMaster)
        .length;
    final int referencedCount = allRows
        .where((_DepartmentRow row) => (row.productCount ?? 0) > 0)
        .length;

    return CatalogueShortcuts(
      onSearch: _searchFocus.requestFocus,
      onNew: () {
        if (_can(PermissionAction.create)) _openDrawer(null);
      },
      onEscape: _onEscape,
      onNext: () => _view.moveActive(_visibleIds, 1),
      onPrevious: () => _view.moveActive(_visibleIds, -1),
      onOpen: () {
        final String? id = _view.activeId;
        if (id == null) return;
        for (final _DepartmentRow row in rows) {
          if (row.id == id && row.isMaster) {
            _openDrawer(row);
            return;
          }
        }
      },
      child: CatalogueWorkspace(
        title: 'Department list',
        subtitle: productSnap.hasError
            ? '${departments.length} saved · product usage unavailable'
            : '${departments.length} saved · $referencedCount referenced by products',
        issues: <CatalogueIssueCount>[
          CatalogueIssueCount(
            label: 'Hidden',
            count: hiddenCount,
            active: (_view.filters['status'] ?? <String>{}).contains('Hidden'),
            onTap: () => _toggleFilter('status', 'Hidden'),
          ),
          if (!productSnap.hasError) ...<CatalogueIssueCount>[
            CatalogueIssueCount(
              label: 'From products',
              count: inferredCount,
              tone: CatalogueTone.info,
              active: _view.presetId == 'inferred',
              onTap: () => _view.setPreset(
                _view.presetId == 'inferred' ? 'all' : 'inferred',
              ),
            ),
            CatalogueIssueCount(
              label: 'In product data',
              count: referencedCount,
              tone: CatalogueTone.neutral,
              active: (_view.filters['usage'] ?? <String>{}).contains(
                'Referenced',
              ),
              onTap: () => _toggleFilter('usage', 'Referenced'),
            ),
          ],
        ],
        primaryAction: FilledButton.icon(
          onPressed: _can(PermissionAction.create)
              ? () => _openDrawer(null)
              : null,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add department'),
        ),
        toolbar: CatalogueToolbar<_DepartmentRow>(
          key: _toolbarKey,
          search: _searchController,
          searchFocus: _searchFocus,
          searchHint: 'Search departments and codes',
          filters: <CatalogueFilterMenu>[
            CatalogueFilterMenu(
              label: 'Status',
              options: const <String>['Active', 'Hidden'],
              selected: _view.filters['status'] ?? <String>{},
              onChanged: (Set<String> value) =>
                  _view.setFilter('status', value),
            ),
            CatalogueFilterMenu(
              label: 'Source',
              options: const <String>['Master', 'From products'],
              selected: _view.filters['source'] ?? <String>{},
              onChanged: (Set<String> value) =>
                  _view.setFilter('source', value),
            ),
          ],
          presets: _presets,
          presetId: _view.presetId,
          onPreset: _view.setPreset,
          columns: columns,
          hiddenColumnIds: _view.hiddenColumnIds,
          onColumns: _view.setHiddenColumns,
          density: _view.density,
          onDensity: _view.setDensity,
          hasActiveFilters: _view.hasActiveFilters || _view.query.isNotEmpty,
          resultSummary:
              'Showing ${rows.length} of ${allRows.length}${_view.showingCloseMatches ? ' · no exact match, showing close spellings' : ''}',
          onClearFilters: _clearFilters,
        ),
        body: _buildBody(departmentSnap, productSnap, allRows, rows, columns),
        drawerOpen: _drawerOpen,
        onCloseDrawer: _requestCloseDrawer,
        drawer: CatalogueDrawer(
          title: _editingId == null ? 'Create Department' : 'Edit Department',
          dirty: _dirty,
          onClose: _closeDrawer,
          body: _buildForm(),
          footer: <Widget>[
            TextButton(
              onPressed: _requestCloseDrawer,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saving || !_canSaveCurrent ? null : _saveDepartment,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_editingId == null ? 'Create' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    AsyncSnapshot<List<_Row>> departmentSnap,
    AsyncSnapshot<List<_Row>> productSnap,
    List<_DepartmentRow> allRows,
    List<_DepartmentRow> rows,
    List<CatalogueColumn<_DepartmentRow>> columns,
  ) {
    if (departmentSnap.hasError) return _errorWidget(departmentSnap.error);
    if ((!departmentSnap.hasData &&
            departmentSnap.connectionState == ConnectionState.waiting) ||
        (!productSnap.hasError &&
            !productSnap.hasData &&
            productSnap.connectionState == ConnectionState.waiting)) {
      return const CatalogueLoading();
    }
    final Widget content;
    if (allRows.isEmpty) {
      content = CatalogueEmpty(
        title: 'No departments yet',
        message: productSnap.hasError
            ? 'Create a department. Product-derived departments are unavailable because product data could not be loaded.'
            : 'Create a department or add product items with department names.',
      );
    } else if (rows.isEmpty) {
      content = CatalogueNoResults(onClear: _clearFilters);
    } else {
      content = CatalogueTable<_DepartmentRow>(
        rows: rows,
        idOf: (_DepartmentRow row) => row.id,
        labelOf: (_DepartmentRow row) => row.name,
        columns: columns,
        state: _view,
        selectable: false,
        semanticsLabelPrefix: 'Department',
        onOpen: (_DepartmentRow row) {
          if (row.isMaster) _openDrawer(row);
        },
        rowActions: (_DepartmentRow row) => row.isMaster
            ? <CatalogueRowAction<_DepartmentRow>>[
                CatalogueRowAction<_DepartmentRow>(
                  label: 'Edit',
                  icon: Icons.edit_outlined,
                  onPressed: _openDrawer,
                ),
              ]
            : <CatalogueRowAction<_DepartmentRow>>[],
      );
    }
    if (!productSnap.hasError) return content;
    return Column(
      children: <Widget>[
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: context.dso.surfaceSoft,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            'Product data is unavailable. Product counts and inferred departments are hidden until it can be loaded.',
          ),
        ),
        Expanded(child: content),
      ],
    );
  }

  Widget _errorWidget(Object? error) {
    if (error is FirebaseException && error.code == 'permission-denied') {
      return const CataloguePermissionDenied();
    }
    return CatalogueError(
      message: userFacingError(error ?? 'unknown', action: 'load departments'),
    );
  }

  Widget _buildForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Departments are global master records. Retailer-specific PIC assignments are handled in Retailer Department PIC.',
          style: TextStyle(fontSize: 13, color: context.dso.muted, height: 1.4),
        ),
        const SizedBox(height: 18),
        const CmsFormLabel(label: 'Department Name'),
        CmsInput(controller: _departmentController, hintText: 'Beverage'),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const CmsFormLabel(label: 'Department Code'),
                  CmsInput(controller: _codeController, hintText: 'BEV'),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const CmsFormLabel(label: 'Sort Order'),
                  CmsInput(controller: _sortController, hintText: '1'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SwitchListTile.adaptive(
          value: _isActive,
          contentPadding: EdgeInsets.zero,
          title: const Text('Active'),
          onChanged: (bool value) {
            _isActive = value;
            _formRevision.value++;
          },
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _clearForm,
          icon: const Icon(Icons.refresh_outlined),
          label: const Text('Clear'),
        ),
      ],
    );
  }

  List<_DepartmentRow> _buildDepartmentRows(
    List<_Row> departments,
    Map<String, _DepartmentSummary> summaries, {
    required bool productsAvailable,
  }) {
    final Set<String> usedKeys = <String>{};
    final List<_DepartmentRow> rows = <_DepartmentRow>[];

    for (final _Row row in departments) {
      final String name = _readText(
        row,
        'departmentName',
        fallbackKeys: <String>['name'],
      );
      final String key = _normaliseKey(name);
      usedKeys.add(key);
      final _DepartmentSummary? summary = summaries[key];
      rows.add(
        _DepartmentRow(
          id: _readText(
            row,
            'docId',
            fallbackKeys: <String>['departmentId'],
            fallback: _cleanDocId(name),
          ),
          source: row,
          name: name,
          code: _normaliseDepartmentCode(
            _readText(row, 'departmentCode'),
            departmentName: name,
          ),
          mainCategoryCount: productsAvailable
              ? summary?.mainCategories.length ?? 0
              : null,
          productCount: productsAvailable ? summary?.productCount ?? 0 : null,
          isActive:
              row['isActive'] != false &&
              _readText(row, 'status').toLowerCase() != 'hidden',
          isMaster: true,
          sortOrder:
              int.tryParse(_readText(row, 'sortOrder', fallback: '0')) ?? 0,
          mainCategories: summary?.mainCategories ?? <String>{},
        ),
      );
    }

    for (final MapEntry<String, _DepartmentSummary> entry
        in summaries.entries) {
      if (usedKeys.contains(entry.key)) continue;
      final _DepartmentSummary summary = entry.value;
      rows.add(
        _DepartmentRow(
          id: 'products-${entry.key}',
          source: null,
          name: summary.departmentName,
          code: _normaliseDepartmentCode(
            '',
            departmentName: summary.departmentName,
          ),
          mainCategoryCount: productsAvailable
              ? summary.mainCategories.length
              : null,
          productCount: productsAvailable ? summary.productCount : null,
          isActive: true,
          isMaster: false,
          sortOrder: 0,
          mainCategories: summary.mainCategories,
        ),
      );
    }
    return rows;
  }

  List<CatalogueColumn<_DepartmentRow>> _columns() =>
      <CatalogueColumn<_DepartmentRow>>[
        CatalogueColumn<_DepartmentRow>(
          id: 'department',
          label: 'Department',
          width: 220,
          flex: 2,
          hideable: false,
          sortKey: (_DepartmentRow row) => row.name.toLowerCase(),
          cell: (BuildContext context, _DepartmentRow row) => Text(
            row.name.isEmpty ? '—' : row.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        CatalogueColumn<_DepartmentRow>(
          id: 'code',
          label: 'Code',
          width: 90,
          sortKey: (_DepartmentRow row) => row.code.toLowerCase(),
          cell: (BuildContext context, _DepartmentRow row) =>
              Text(row.code.isEmpty ? '—' : row.code),
        ),
        CatalogueColumn<_DepartmentRow>(
          id: 'categories',
          label: 'Main categories',
          width: 120,
          numeric: true,
          sortKey: (_DepartmentRow row) => row.mainCategoryCount ?? -1,
          cell: (BuildContext context, _DepartmentRow row) =>
              Text(row.mainCategoryCount?.toString() ?? '—'),
        ),
        CatalogueColumn<_DepartmentRow>(
          id: 'products',
          label: 'Products',
          width: 100,
          numeric: true,
          sortKey: (_DepartmentRow row) => row.productCount ?? -1,
          cell: (BuildContext context, _DepartmentRow row) =>
              Text(row.productCount?.toString() ?? '—'),
        ),
        CatalogueColumn<_DepartmentRow>(
          id: 'status',
          label: 'Status',
          width: 105,
          hideable: false,
          sortKey: (_DepartmentRow row) =>
              row.isMaster ? (row.isActive ? 'active' : 'hidden') : 'products',
          cell: (BuildContext context, _DepartmentRow row) => Align(
            alignment: Alignment.centerLeft,
            child: CatalogueStatusPill(
              label: row.isMaster ? (row.isActive ? 'Active' : 'Hidden') : '—',
              tone: row.isMaster && row.isActive
                  ? CatalogueTone.success
                  : row.isMaster
                  ? CatalogueTone.neutral
                  : CatalogueTone.info,
            ),
          ),
        ),
        CatalogueColumn<_DepartmentRow>(
          id: 'source',
          label: 'Source',
          width: 125,
          sortKey: (_DepartmentRow row) => row.isMaster ? 'master' : 'products',
          cell: (BuildContext context, _DepartmentRow row) =>
              Text(row.isMaster ? 'Master' : 'From products'),
        ),
      ];

  List<CataloguePreset<_DepartmentRow>> get _presets =>
      <CataloguePreset<_DepartmentRow>>[
        CataloguePreset<_DepartmentRow>(
          id: 'all',
          label: 'All departments',
          test: (_DepartmentRow _) => true,
        ),
        CataloguePreset<_DepartmentRow>(
          id: 'inferred',
          label: 'From products',
          test: (_DepartmentRow row) => !row.isMaster,
        ),
      ];

  String _searchBlob(_DepartmentRow row) => <String>[
    row.name,
    row.code,
    row.mainCategories.join(' '),
    row.isMaster ? (row.isActive ? 'active' : 'hidden') : 'from products',
  ].join(' ').toLowerCase();

  int _defaultOrder(_DepartmentRow a, _DepartmentRow b) {
    if (a.isMaster != b.isMaster) return a.isMaster ? -1 : 1;
    if (a.isMaster && a.sortOrder != b.sortOrder) {
      return a.sortOrder.compareTo(b.sortOrder);
    }
    return a.name.compareTo(b.name);
  }

  Map<String, _DepartmentSummary> _buildSummaries(List<_Row> rows) {
    final Map<String, _DepartmentSummary> grouped =
        <String, _DepartmentSummary>{};
    for (final _Row row in rows) {
      final String departmentName = _readText(row, 'departmentName');
      if (departmentName.isEmpty) continue;
      final String key = _normaliseKey(departmentName);
      final _DepartmentSummary summary = grouped.putIfAbsent(
        key,
        () => _DepartmentSummary(departmentName: departmentName),
      );
      final String main = _readText(
        row,
        'mainCategoryName',
        fallbackKeys: <String>['categoryName'],
      );
      if (main.isNotEmpty) summary.mainCategories.add(main);
      summary.productCount++;
    }
    return grouped;
  }

  int _compareDepartmentRows(_Row a, _Row b) {
    final int orderA =
        int.tryParse(_readText(a, 'sortOrder', fallback: '0')) ?? 0;
    final int orderB =
        int.tryParse(_readText(b, 'sortOrder', fallback: '0')) ?? 0;
    if (orderA != orderB) return orderA.compareTo(orderB);
    return _readText(
      a,
      'departmentName',
      fallbackKeys: <String>['name'],
    ).compareTo(_readText(b, 'departmentName', fallbackKeys: <String>['name']));
  }

  String _cleanDocId(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  String _normaliseKey(String text) => text.trim().toLowerCase();

  String _normaliseDepartmentCode(
    String raw, {
    required String departmentName,
  }) {
    final String code = raw.trim();
    if (!_isPlaceholder(code)) return code.toUpperCase();
    final String normalisedName = departmentName.trim().toUpperCase();
    if (normalisedName == 'ORGANIC') return 'ORG';
    if (normalisedName == 'SUPERMARKET') return 'SUP';
    final String generated = normalisedName.replaceAll(
      RegExp(r'[^A-Z0-9]'),
      '',
    );
    if (generated.length >= 3) return generated.substring(0, 3);
    if (generated.isNotEmpty) return generated.padRight(3, 'X');
    return '';
  }

  bool _isPlaceholder(String value) {
    final String text = value.trim();
    final String lower = text.toLowerCase();
    return text.isEmpty ||
        text == '-' ||
        text == '—' ||
        text == '\u00e2\u20ac\u201d' ||
        text == '\u00c3\u00a2\u00e2\u201a\u00ac\u00e2\u20ac\u009d' ||
        lower == 'null' ||
        lower == 'n/a' ||
        lower == 'na';
  }

  String _readText(
    Map<String, dynamic> row,
    String key, {
    List<String> fallbackKeys = const <String>[],
    String fallback = '',
  }) {
    for (final String currentKey in <String>[key, ...fallbackKeys]) {
      final Object? value = row[currentKey];
      final String text = '$value'.trim();
      if (text.isNotEmpty && text != 'null') return text;
    }
    return fallback;
  }
}

class _DepartmentRow {
  const _DepartmentRow({
    required this.id,
    required this.source,
    required this.name,
    required this.code,
    required this.mainCategoryCount,
    required this.productCount,
    required this.isActive,
    required this.isMaster,
    required this.sortOrder,
    required this.mainCategories,
  });

  final String id;
  final _Row? source;
  final String name;
  final String code;
  final int? mainCategoryCount;
  final int? productCount;
  final bool isActive;
  final bool isMaster;
  final int sortOrder;
  final Set<String> mainCategories;
}

class _DepartmentSummary {
  _DepartmentSummary({required this.departmentName});

  final String departmentName;
  final Set<String> mainCategories = <String>{};
  int productCount = 0;
}
