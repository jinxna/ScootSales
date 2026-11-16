import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../app/permission_policy.dart';
import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../utils/cms_permissions.dart';
import '../../../utils/safe_doc_id.dart';
import '../../../utils/user_facing_error.dart';
import '../../../widgets/cms_feedback.dart';
import '../../../widgets/confirm_destructive_dialog.dart';
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

class CategoryCmsPage extends StatefulWidget {
  const CategoryCmsPage({super.key, this.currentUser});

  final UserProfile? currentUser;

  @override
  State<CategoryCmsPage> createState() => _CategoryCmsPageState();
}

class _CategoryCmsPageState extends State<CategoryCmsPage> {
  final CmsRepository _repository = CmsRepository();
  final CatalogueViewState<_Row> _view = CatalogueViewState<_Row>();
  final FocusNode _searchFocus = FocusNode();
  final GlobalKey<CatalogueToolbarState<_Row>> _toolbarKey =
      GlobalKey<CatalogueToolbarState<_Row>>();
  final ValueNotifier<int> _formRevision = ValueNotifier<int>(0);

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _positionController = TextEditingController();

  late final Stream<List<_Row>> _departmentStream = _repository.watchCollection(
    'departments',
  );
  late final Stream<List<_Row>> _categoryStream = _repository.watchCollection(
    'categories',
  );

  String _status = 'Display';
  String? _selectedDepartmentId;
  String? _selectedDepartmentName;
  String? _editingId;
  bool _drawerOpen = false;
  bool _saving = false;
  String _formSnapshot = '';
  List<String> _visibleIds = <String>[];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => _view.setQuery(_searchController.text));
    _nameController.addListener(_onFormChanged);
    _positionController.addListener(_onFormChanged);
  }

  @override
  void dispose() {
    _view.dispose();
    _searchFocus.dispose();
    _formRevision.dispose();
    _searchController.dispose();
    _nameController.dispose();
    _positionController.dispose();
    super.dispose();
  }

  void _onFormChanged() {
    if (_drawerOpen) _formRevision.value++;
  }

  String _formSignature() => <String>[
    _nameController.text,
    _positionController.text,
    _status,
    _selectedDepartmentId ?? '',
    _selectedDepartmentName ?? '',
  ].join('\u0000');

  bool get _dirty => _drawerOpen && _formSignature() != _formSnapshot;

  bool _can(PermissionAction action) =>
      cmsActionAllowed(widget.currentUser, 'categories', action);

  bool get _canSaveCurrent => _can(
    _editingId == null ? PermissionAction.create : PermissionAction.edit,
  );

  Future<void> _saveCategory() async {
    if (_saving) return;
    final String categoryName = _nameController.text.trim();
    final String departmentName = (_selectedDepartmentName ?? '').trim();
    final String departmentId = (_selectedDepartmentId ?? '').trim();

    if (departmentName.isEmpty || categoryName.isEmpty) {
      showCmsToast(
        context,
        'Select a department and enter the main category name.',
        isError: true,
      );
      return;
    }

    final bool creating = _editingId == null;
    String categoryId =
        _editingId ?? _cleanDocId('$departmentId $categoryName');
    if (categoryId.isEmpty) {
      categoryId = safeDocId(
        '$departmentId $categoryName',
        fallbackPrefix: 'category',
      );
    }
    final Map<String, dynamic> data = <String, dynamic>{
      'categoryId': categoryId,
      'mainCategoryId': categoryId,
      'departmentId': departmentId,
      'departmentName': departmentName,
      'mainCategoryName': categoryName,
      'categoryName': categoryName,
      'name': categoryName,
      'position': int.tryParse(_positionController.text.trim()) ?? 0,
      'sortOrder': int.tryParse(_positionController.text.trim()) ?? 0,
      'status': _status == 'Display' ? 'active' : 'hidden',
      'isActive': _status == 'Display',
    };
    setState(() => _saving = true);
    try {
      if (creating) {
        await _repository.createDocumentIfAbsent(
          collectionName: 'categories',
          docId: categoryId,
          data: <String, dynamic>{
            ...data,
            'createdAt': FieldValue.serverTimestamp(),
          },
          duplicateMessage:
              'a main category named "$categoryName" already exists in this '
              'department. Open it from the list to edit it.',
        );
      } else {
        await _repository.upsertDocument(
          collectionName: 'categories',
          docId: categoryId,
          data: data,
        );
      }
      if (!mounted) return;
      showCmsToast(
        context,
        creating ? 'Main category created.' : 'Main category saved.',
      );
      _closeDrawer();
    } catch (error) {
      if (!mounted) return;
      showCmsToast(
        context,
        userFacingError(error, action: 'save the main category'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _fillForm(_Row? category) {
    setState(() {
      if (category == null) {
        _resetFields();
      } else {
        _editingId = _readText(
          category,
          'docId',
          fallbackKeys: <String>['categoryId', 'mainCategoryId'],
        );
        _selectedDepartmentId = _readText(
          category,
          'departmentId',
          fallback: _cleanDocId(_readText(category, 'departmentName')),
        );
        _selectedDepartmentName = _readText(category, 'departmentName');
        _nameController.text = _readText(
          category,
          'mainCategoryName',
          fallbackKeys: <String>['categoryName', 'name'],
        );
        _positionController.text = _readText(
          category,
          'position',
          fallbackKeys: <String>['sortOrder'],
          fallback: '0',
        );
        _status = _isDisplay(category) ? 'Display' : 'Hide';
      }
      _drawerOpen = true;
      _formSnapshot = _formSignature();
    });
    _formRevision.value++;
  }

  void _resetFields() {
    _editingId = null;
    _nameController.clear();
    _positionController.clear();
    _status = 'Display';
    _selectedDepartmentId = null;
    _selectedDepartmentName = null;
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

  void _openDrawer(_Row? category) => closeCatalogueDrawer(
    context,
    dirty: _dirty,
    onClose: () => _fillForm(category),
  );

  void _requestCloseDrawer() =>
      closeCatalogueDrawer(context, dirty: _dirty, onClose: _closeDrawer);

  Future<void> _deleteCategory(_Row category) async {
    if (_saving) return;
    final String docId = _readText(category, 'docId');
    if (docId.isEmpty) return;
    final String name = _categoryName(category);
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Delete main category?',
      message:
          'Delete "$name"? Products already filed under it keep their text '
          'but the category will no longer appear in this list. This cannot '
          'be undone.',
    );
    if (!confirmed || !mounted) return;
    setState(() => _saving = true);
    try {
      await _repository.deleteDocument(
        collectionName: 'categories',
        docId: docId,
      );
      if (!mounted) return;
      showCmsToast(context, 'Main category deleted.');
      if (_editingId == docId) _closeDrawer();
    } catch (error) {
      if (!mounted) return;
      showCmsToast(
        context,
        userFacingError(error, action: 'delete the main category'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

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
              stream: _categoryStream,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<List<_Row>> categorySnap,
                  ) {
                    return ListenableBuilder(
                      listenable: _view,
                      builder: (BuildContext context, Widget? _) =>
                          ValueListenableBuilder<int>(
                            valueListenable: _formRevision,
                            builder: (_, _, _) => _buildWorkspace(
                              context,
                              departmentSnap,
                              categorySnap,
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
    AsyncSnapshot<List<_Row>> categorySnap,
  ) {
    final List<_Row> departments =
        List<_Row>.of(departmentSnap.data ?? <_Row>[])..sort(
          (_Row a, _Row b) => _departmentName(a).compareTo(_departmentName(b)),
        );
    final List<_Row> categories = _dedupeCategoryRows(
      List<_Row>.of(categorySnap.data ?? <_Row>[]),
    )..sort(_compareCategoryRows);
    final List<CatalogueColumn<_Row>> columns = _columns();
    final List<_Row> rows = _view.apply(
      categories,
      idOf: _id,
      searchBlob: _searchBlob,
      filterValue: <String, String Function(_Row)>{
        'department': (_Row row) => _readText(
          row,
          'departmentName',
          fallbackKeys: <String>['department'],
        ),
        'status': (_Row row) => _isDisplay(row) ? 'Display' : 'Hidden',
      },
      columns: columns,
      defaultSort: _compareCategoryRows,
      presets: _presets,
    );
    _visibleIds = rows.map(_id).toList();

    final int hiddenCount = categories
        .where((_Row item) => !_isDisplay(item))
        .length;
    final int displayCount = categories.length - hiddenCount;
    final List<String> departmentOptions =
        categories
            .map((_Row row) => _readText(row, 'departmentName'))
            .where((String name) => name.isNotEmpty)
            .toSet()
            .toList()
          ..sort();

    return CatalogueShortcuts(
      onSearch: _searchFocus.requestFocus,
      onNew: () {
        if (!departmentSnap.hasError && _can(PermissionAction.create)) {
          _openDrawer(null);
        }
      },
      onEscape: _onEscape,
      onNext: () => _view.moveActive(_visibleIds, 1),
      onPrevious: () => _view.moveActive(_visibleIds, -1),
      onOpen: () {
        final String? id = _view.activeId;
        if (id == null) return;
        for (final _Row row in rows) {
          if (_id(row) == id) {
            _openDrawer(row);
            return;
          }
        }
      },
      child: CatalogueWorkspace(
        title: 'Category list',
        subtitle:
            '${categories.length} main categories · ${departmentSnap.hasData ? departments.length : departmentOptions.length} departments',
        issues: <CatalogueIssueCount>[
          CatalogueIssueCount(
            label: 'Display',
            count: displayCount,
            tone: CatalogueTone.success,
            active: (_view.filters['status'] ?? <String>{}).contains('Display'),
            onTap: () => _toggleFilter('status', 'Display'),
          ),
          CatalogueIssueCount(
            label: 'Hidden',
            count: hiddenCount,
            active: (_view.filters['status'] ?? <String>{}).contains('Hidden'),
            onTap: () => _toggleFilter('status', 'Hidden'),
          ),
        ],
        primaryAction: FilledButton.icon(
          onPressed: departmentSnap.hasError || !_can(PermissionAction.create)
              ? null
              : () => _openDrawer(null),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add category'),
        ),
        toolbar: CatalogueToolbar<_Row>(
          key: _toolbarKey,
          search: _searchController,
          searchFocus: _searchFocus,
          searchHint: 'Search categories and departments',
          filters: <CatalogueFilterMenu>[
            CatalogueFilterMenu(
              label: 'Department',
              options: departmentOptions,
              selected: _view.filters['department'] ?? <String>{},
              onChanged: (Set<String> value) =>
                  _view.setFilter('department', value),
            ),
            CatalogueFilterMenu(
              label: 'Status',
              options: const <String>['Display', 'Hidden'],
              selected: _view.filters['status'] ?? <String>{},
              onChanged: (Set<String> value) =>
                  _view.setFilter('status', value),
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
              'Showing ${rows.length} of ${categories.length}${_view.showingCloseMatches ? ' · no exact match, showing close spellings' : ''}',
          onClearFilters: _clearFilters,
        ),
        body: _buildBody(
          departmentSnap,
          categorySnap,
          categories,
          rows,
          columns,
        ),
        drawerOpen: _drawerOpen,
        onCloseDrawer: _requestCloseDrawer,
        drawer: CatalogueDrawer(
          title: _editingId == null
              ? 'Add Main Category'
              : 'Edit Main Category',
          dirty: _dirty,
          onClose: _closeDrawer,
          body: _buildForm(departments),
          footer: <Widget>[
            if (_editingId != null && _can(PermissionAction.delete))
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: context.dso.dangerText,
                ),
                onPressed: _saving
                    ? null
                    : () {
                        final _Row? category = categories
                            .where((_Row row) => _id(row) == _editingId)
                            .firstOrNull;
                        if (category != null) _deleteCategory(category);
                      },
                child: const Text('Delete'),
              ),
            const Spacer(),
            TextButton(
              onPressed: _requestCloseDrawer,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saving || !_canSaveCurrent ? null : _saveCategory,
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
    AsyncSnapshot<List<_Row>> categorySnap,
    List<_Row> allRows,
    List<_Row> rows,
    List<CatalogueColumn<_Row>> columns,
  ) {
    if (categorySnap.hasError) return _errorWidget(categorySnap.error);
    if ((!departmentSnap.hasError &&
            !departmentSnap.hasData &&
            departmentSnap.connectionState == ConnectionState.waiting) ||
        (!categorySnap.hasData &&
            categorySnap.connectionState == ConnectionState.waiting)) {
      return const CatalogueLoading();
    }
    final Widget content;
    if (allRows.isEmpty) {
      content = const CatalogueEmpty(
        title: 'No main categories found',
        message: 'No categories yet. Add one with Add category.',
      );
    } else if (rows.isEmpty) {
      content = CatalogueNoResults(onClear: _clearFilters);
    } else {
      content = CatalogueTable<_Row>(
        rows: rows,
        idOf: _id,
        labelOf: _categoryName,
        columns: columns,
        state: _view,
        selectable: false,
        semanticsLabelPrefix: 'Category',
        groupOf: (_Row row) =>
            _readText(row, 'departmentName', fallback: 'No department'),
        onOpen: departmentSnap.hasError ? null : _openDrawer,
        rowActions: (_Row row) => <CatalogueRowAction<_Row>>[
          if (!departmentSnap.hasError)
            CatalogueRowAction<_Row>(
              label: 'Edit',
              icon: Icons.edit_outlined,
              onPressed: _openDrawer,
            ),
          if (_can(PermissionAction.delete))
            CatalogueRowAction<_Row>(
              label: 'Delete',
              icon: Icons.delete_outline,
              destructive: true,
              onPressed: _deleteCategory,
            ),
        ],
      );
    }
    if (!departmentSnap.hasError) return content;
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
            'The department list could not be loaded. Existing categories remain visible, but create and edit are disabled until it is available.',
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
      message: userFacingError(error ?? 'unknown', action: 'load categories'),
    );
  }

  Widget _buildForm(List<_Row> departments) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Main categories are global catalogue records under one department. Retailers reuse these through their score sheet settings.',
          style: TextStyle(fontSize: 13, color: context.dso.muted, height: 1.4),
        ),
        const SizedBox(height: 16),
        const CmsFormLabel(label: 'Department'),
        DropdownButtonFormField<String>(
          key: ValueKey<String?>(_selectedDepartmentId),
          initialValue:
              departments.any(
                (_Row item) => _departmentId(item) == _selectedDepartmentId,
              )
              ? _selectedDepartmentId
              : null,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: departments.map((_Row department) {
            final String id = _departmentId(department);
            return DropdownMenuItem<String>(
              value: id,
              child: Text(
                _departmentName(department),
                overflow: TextOverflow.ellipsis,
              ),
            );
          }).toList(),
          onChanged: (String? value) {
            final _Row selected = departments.firstWhere(
              (_Row item) => _departmentId(item) == value,
              orElse: () => <String, dynamic>{},
            );
            _selectedDepartmentId = value;
            _selectedDepartmentName = _departmentName(selected);
            _formRevision.value++;
          },
        ),
        const SizedBox(height: 16),
        const CmsFormLabel(label: 'Main Category'),
        CmsInput(
          controller: _nameController,
          hintText: 'MONTANNA ORGANIC & NATURAL VINEGAR',
        ),
        const SizedBox(height: 16),
        const CmsFormLabel(label: 'Position'),
        CmsInput(controller: _positionController, hintText: '1'),
        const SizedBox(height: 16),
        const CmsFormLabel(label: 'Status'),
        CmsDropdown(
          value: _status,
          items: const <String>['Display', 'Hide'],
          onChanged: (String? value) {
            _status = value ?? 'Display';
            _formRevision.value++;
          },
        ),
        const SizedBox(height: 20),
        OutlinedButton(onPressed: _clearForm, child: const Text('Reset')),
      ],
    );
  }

  List<CatalogueColumn<_Row>> _columns() => <CatalogueColumn<_Row>>[
    CatalogueColumn<_Row>(
      id: 'name',
      label: 'Main category',
      width: 300,
      flex: 2,
      hideable: false,
      sortKey: (_Row row) => _categoryName(row).toLowerCase(),
      cell: (BuildContext context, _Row row) => Text(
        _categoryName(row).isEmpty ? '—' : _categoryName(row),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    CatalogueColumn<_Row>(
      id: 'department',
      label: 'Department',
      width: 180,
      sortKey: (_Row row) => _departmentName(row).toLowerCase(),
      cell: (BuildContext context, _Row row) => Text(
        _departmentName(row).isEmpty ? '—' : _departmentName(row),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    CatalogueColumn<_Row>(
      id: 'position',
      label: 'Position',
      width: 90,
      numeric: true,
      sortKey: (_Row row) =>
          int.tryParse(
            _readText(row, 'position', fallbackKeys: <String>['sortOrder']),
          ) ??
          0,
      cell: (BuildContext context, _Row row) => Text(
        _readText(
          row,
          'position',
          fallbackKeys: <String>['sortOrder'],
          fallback: '0',
        ),
      ),
    ),
    CatalogueColumn<_Row>(
      id: 'status',
      label: 'Status',
      width: 110,
      hideable: false,
      sortKey: (_Row row) => _isDisplay(row) ? 'display' : 'hidden',
      cell: (BuildContext context, _Row row) => Align(
        alignment: Alignment.centerLeft,
        child: CatalogueStatusPill(
          label: _isDisplay(row) ? 'Display' : 'Hidden',
          tone: _isDisplay(row) ? CatalogueTone.success : CatalogueTone.neutral,
        ),
      ),
    ),
  ];

  List<CataloguePreset<_Row>> get _presets => <CataloguePreset<_Row>>[
    CataloguePreset<_Row>(
      id: 'all',
      label: 'All categories',
      test: (_Row _) => true,
    ),
    CataloguePreset<_Row>(id: 'display', label: 'Display', test: _isDisplay),
    CataloguePreset<_Row>(
      id: 'hidden',
      label: 'Hidden',
      test: (_Row row) => !_isDisplay(row),
    ),
  ];

  String _searchBlob(_Row row) => <String>[
    _categoryName(row),
    _departmentName(row),
    _readText(row, 'position', fallbackKeys: <String>['sortOrder']),
    _isDisplay(row) ? 'display' : 'hidden',
  ].join(' ').toLowerCase();

  String _id(_Row row) => _readText(
    row,
    'docId',
    fallbackKeys: <String>['categoryId', 'mainCategoryId'],
  );

  String _categoryName(_Row row) => _readText(
    row,
    'mainCategoryName',
    fallbackKeys: <String>['categoryName', 'name'],
  );

  List<_Row> _dedupeCategoryRows(List<_Row> rows) {
    final Map<String, _Row> byKey = <String, _Row>{};
    for (final _Row row in rows) {
      final String key = _dedupeKey(row);
      final _Row? existing = byKey[key];
      if (existing == null || _categoryScore(row) > _categoryScore(existing)) {
        byKey[key] = row;
      }
    }
    return byKey.values.toList();
  }

  String _dedupeKey(_Row row) {
    final String department = _readText(
      row,
      'departmentName',
      fallbackKeys: <String>['department'],
      fallback: 'GENERAL',
    );
    final String category = _readText(
      row,
      'mainCategoryName',
      fallbackKeys: <String>['categoryName', 'name'],
      fallback: 'UNCATEGORISED',
    );
    return '${_cleanDocId(department)}::${_cleanDocId(category)}';
  }

  int _categoryScore(_Row row) {
    final String id = _readText(row, 'docId');
    final String departmentId = _readText(
      row,
      'departmentId',
      fallback: _cleanDocId(_readText(row, 'departmentName')),
    );
    final String name = _readText(
      row,
      'mainCategoryName',
      fallbackKeys: <String>['categoryName', 'name'],
    );
    final String canonicalId = _cleanDocId('$departmentId $name');
    int score = 0;
    if (id == canonicalId) score += 1000;
    if (id.contains('_')) score += 100;
    if (_readText(row, 'categoryId').isNotEmpty) score += 60;
    if (_readText(row, 'mainCategoryId').isNotEmpty) score += 50;
    if (_readText(row, 'departmentId').isNotEmpty) score += 40;
    if (_isDisplay(row)) score += 10;
    return score;
  }

  int _compareCategoryRows(_Row a, _Row b) {
    final int department = _readText(
      a,
      'departmentName',
    ).compareTo(_readText(b, 'departmentName'));
    if (department != 0) return department;
    final int orderA =
        int.tryParse(
          _readText(
            a,
            'position',
            fallbackKeys: <String>['sortOrder'],
            fallback: '0',
          ),
        ) ??
        0;
    final int orderB =
        int.tryParse(
          _readText(
            b,
            'position',
            fallbackKeys: <String>['sortOrder'],
            fallback: '0',
          ),
        ) ??
        0;
    if (orderA != orderB) return orderA.compareTo(orderB);
    return _categoryName(a).compareTo(_categoryName(b));
  }

  bool _isDisplay(_Row row) {
    final String status = _readText(row, 'status').toLowerCase();
    return row['isActive'] != false &&
        status != 'hide' &&
        status != 'hidden' &&
        status != 'inactive';
  }

  String _departmentId(_Row row) {
    return _readText(
      row,
      'departmentId',
      fallbackKeys: <String>['docId'],
      fallback: _cleanDocId(_departmentName(row)),
    );
  }

  String _departmentName(_Row row) {
    return _readText(
      row,
      'departmentName',
      fallbackKeys: <String>['name'],
      fallback: '-',
    );
  }

  String _cleanDocId(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

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
