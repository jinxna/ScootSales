import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../app/permission_policy.dart';
import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../services/permission_policy_service.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/cms_permissions.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/retailer_scope.dart';
import '../../../utils/user_facing_error.dart';
import '../../../widgets/cms_feedback.dart';
import '../../../widgets/confirm_destructive_dialog.dart';
import '../../../widgets/catalogue/catalogue_column.dart';
import '../../../widgets/catalogue/catalogue_drawer.dart';
import '../../../widgets/catalogue/catalogue_shortcuts.dart';
import '../../../widgets/catalogue/catalogue_states.dart';
import '../../../widgets/catalogue/catalogue_status_pill.dart';
import '../../../widgets/catalogue/catalogue_table.dart';
import '../../../widgets/catalogue/catalogue_toolbar.dart';
import '../../../widgets/catalogue/catalogue_view_state.dart';
import '../../../widgets/catalogue/catalogue_workspace.dart';

const Color _green = Color(0xFF27AE60);

class DepartmentPicPage extends StatefulWidget {
  const DepartmentPicPage({super.key, this.currentUser});

  final UserProfile? currentUser;

  @override
  State<DepartmentPicPage> createState() => _DepartmentPicPageState();
}

class _DepartmentPicPageState extends State<DepartmentPicPage> {
  final CmsRepository _repository = CmsRepository();
  final TextEditingController _picNameController = TextEditingController();
  final TextEditingController _picUserIdController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final CatalogueViewState<Map<String, dynamic>> _view =
      CatalogueViewState<Map<String, dynamic>>();

  late final Stream<List<Map<String, dynamic>>> _assignmentsStream = _repository
      .watchCollection('department_pic_assignments');
  late final Stream<List<Map<String, dynamic>>> _retailersStream =
      operationalRetailerStream(_repository.watchCollection('retailers'));
  late final Stream<List<Map<String, dynamic>>> _departmentsStream = _repository
      .watchCollection('departments');

  String? _selectedRetailerId;
  String _selectedRetailerName = '';
  String? _selectedDepartment;
  String _editingDocId = '';
  String _message = '';
  bool _isSaving = false;
  bool _drawerOpen = false;
  bool _densityDefaulted = false;
  String _drawerInitialState = '';

  Set<String> _scopeRetailerIds = <String>{};
  StreamSubscription<List<Map<String, dynamic>>>? _scopeSubscription;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    final UserProfile? actor = widget.currentUser;
    if (actor != null && !actor.isAdmin) {
      _scopeSubscription = _retailersStream.listen((
        List<Map<String, dynamic>> rows,
      ) {
        if (!mounted) return;
        setState(
          () => _scopeRetailerIds = <String>{
            for (final Map<String, dynamic> retailer in rows)
              if (retailerInActorScope(actor, retailer)) _retailerId(retailer),
          },
        );
      });
    }
  }

  bool _canManageRow(Map<String, dynamic> row, PermissionAction action) {
    final UserProfile? actor = widget.currentUser;
    return _can(action) &&
        (actor == null ||
            actor.isAdmin ||
            _scopeRetailerIds.contains(_text(row['retailerId'])));
  }

  @override
  void dispose() {
    _scopeSubscription?.cancel();
    _view.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _picNameController.dispose();
    _picUserIdController.dispose();
    super.dispose();
  }

  void _onSearchChanged() => _view.setQuery(_searchController.text);

  String _formStateKey() => <String>[
    _editingDocId,
    _selectedRetailerId ?? '',
    _selectedRetailerName,
    _selectedDepartment ?? '',
    _picNameController.text,
    _picUserIdController.text,
  ].join('\u0000');

  bool get _drawerDirty =>
      _drawerOpen && _formStateKey() != _drawerInitialState;

  void _captureDrawerState() => _drawerInitialState = _formStateKey();

  Future<void> _openCreateDrawer() async {
    if (_isSaving) return;
    if (_drawerOpen) {
      await closeCatalogueDrawer(
        context,
        dirty: _drawerDirty,
        onClose: _closeDrawer,
      );
      if (_drawerOpen) return;
    }
    _picNameController.clear();
    _picUserIdController.clear();
    setState(() {
      _editingDocId = '';
      _selectedDepartment = null;
      _message = '';
      _drawerOpen = true;
      _captureDrawerState();
    });
  }

  void _requestCloseDrawer() =>
      closeCatalogueDrawer(context, dirty: _drawerDirty, onClose: _closeDrawer);

  void _closeDrawer() {
    _picNameController.clear();
    _picUserIdController.clear();
    setState(() {
      _editingDocId = '';
      _selectedRetailerId = null;
      _selectedRetailerName = '';
      _selectedDepartment = null;
      _message = '';
      _drawerOpen = false;
      _captureDrawerState();
    });
  }

  bool _can(PermissionAction action) =>
      cmsActionAllowed(widget.currentUser, 'department_pic', action);

  Future<void> _save() async {
    if (_isSaving) return;
    if (_selectedRetailerId == null) {
      setState(() => _message = 'Please select a retailer first.');
      return;
    }
    if (_selectedDepartment == null || _selectedDepartment!.isEmpty) {
      setState(() => _message = 'Please select a department.');
      return;
    }
    final String picName = _picNameController.text.trim();
    if (picName.isEmpty) {
      setState(() => _message = 'PIC name is required.');
      return;
    }
    final bool creating = _editingDocId.isEmpty;
    setState(() {
      _isSaving = true;
      _message = '';
    });
    try {
      await _repository.upsertDocument(
        collectionName: 'department_pic_assignments',
        docId: creating ? null : _editingDocId,
        data: <String, dynamic>{
          'retailerId': _selectedRetailerId,
          'retailerName': _selectedRetailerName,
          'departmentName': _selectedDepartment,
          'picName': picName,
          'picUserId': _picUserIdController.text.trim(),
          'status': 'active',
        },
      );
      if (!mounted) return;
      showCmsToast(
        context,
        creating ? 'Department PIC added.' : 'Department PIC updated.',
      );
      _closeDrawer();
    } catch (error) {
      if (!mounted) return;
      final String message = userFacingError(
        error,
        action: 'save the department PIC',
      );
      setState(() => _message = message);
      showCmsToast(context, message, isError: true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _edit(Map<String, dynamic> row) async {
    if (_isSaving || !_canManageRow(row, PermissionAction.edit)) return;
    if (_drawerOpen) {
      await closeCatalogueDrawer(
        context,
        dirty: _drawerDirty,
        onClose: _closeDrawer,
      );
      if (_drawerOpen) return;
    }
    _picNameController.text = _text(row['picName']);
    _picUserIdController.text = _text(row['picUserId']);
    setState(() {
      _selectedRetailerId = _text(row['retailerId']);
      _selectedRetailerName = _text(row['retailerName']);
      _selectedDepartment = _text(row['departmentName']);
      _editingDocId = _text(row['docId']);
      _message = '';
      _drawerOpen = true;
      _captureDrawerState();
    });
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final String docId = _text(row['docId']);
    if (docId.isEmpty || _isSaving) return;
    final String retailer = _text(row['retailerName']);
    final String department = _text(row['departmentName']);
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Delete department PIC?',
      message:
          'Remove the PIC for $department at $retailer? This cannot be '
          'undone.',
    );
    if (!confirmed || !mounted) return;
    setState(() => _isSaving = true);
    try {
      await _repository.deleteDocument(
        collectionName: 'department_pic_assignments',
        docId: docId,
      );
      if (!mounted) return;
      showCmsToast(context, 'Department PIC deleted.');
      if (_editingDocId == docId) _closeDrawer();
    } catch (error) {
      if (!mounted) return;
      showCmsToast(
        context,
        userFacingError(error, action: 'delete the department PIC'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_densityDefaulted) {
      _densityDefaulted = true;
      _view.density = MediaQuery.sizeOf(context).width < 900
          ? CatalogueDensity.comfortable
          : CatalogueDensity.compact;
    }

    return ValueListenableBuilder<PermissionPolicy>(
      valueListenable: PermissionPolicyService.instance.policy,
      builder: (BuildContext context, PermissionPolicy _, Widget? child) =>
          _buildLive(),
    );
  }

  Widget _buildLive() {
    return ListenableBuilder(
      listenable: _view,
      builder: (BuildContext context, Widget? child) =>
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _assignmentsStream,
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
                ) {
                  final List<Map<String, dynamic>> rows =
                      snapshot.data ?? <Map<String, dynamic>>[];
                  final List<Map<String, dynamic>> orderedRows = _groupRows(
                    rows,
                  );
                  final List<CatalogueColumn<Map<String, dynamic>>> columns =
                      _columns();
                  final List<Map<String, dynamic>> visibleRows = _view.apply(
                    orderedRows,
                    idOf: _rowId,
                    searchBlob: _searchBlob,
                    filterValue:
                        <String, String Function(Map<String, dynamic>)>{},
                    columns: columns,
                    presets: _presets,
                  );

                  return _buildWorkspace(snapshot, rows, visibleRows, columns);
                },
          ),
    );
  }

  List<CataloguePreset<Map<String, dynamic>>> get _presets =>
      <CataloguePreset<Map<String, dynamic>>>[
        CataloguePreset<Map<String, dynamic>>(
          id: 'all',
          label: 'All assignments',
          test: (_) => true,
        ),
      ];

  String _rowId(Map<String, dynamic> row) => _text(row['docId']);

  String _retailerGroup(Map<String, dynamic> row) {
    final String retailerName = _text(row['retailerName']);
    return retailerName.isNotEmpty ? retailerName : 'Unknown Retailer';
  }

  String _searchBlob(Map<String, dynamic> row) => <String>[
    _text(row['retailerName']),
    _text(row['departmentName']),
    _text(row['picName']),
    _text(row['picUserId']),
    _text(row['retailerId']),
  ].join(' ').toLowerCase();

  List<Map<String, dynamic>> _groupRows(List<Map<String, dynamic>> rows) {
    final Map<String, List<Map<String, dynamic>>> grouped =
        <String, List<Map<String, dynamic>>>{};
    for (final Map<String, dynamic> row in rows) {
      grouped.putIfAbsent(_retailerGroup(row), () => <Map<String, dynamic>>[]);
      grouped[_retailerGroup(row)]!.add(row);
    }
    final List<String> retailers = grouped.keys.toList()..sort();
    return <Map<String, dynamic>>[
      for (final String retailer in retailers) ...grouped[retailer]!,
    ];
  }

  List<CatalogueColumn<Map<String, dynamic>>>
  _columns() => <CatalogueColumn<Map<String, dynamic>>>[
    CatalogueColumn<Map<String, dynamic>>(
      id: 'department',
      label: 'Department',
      width: 190,
      flex: 1,
      hideable: false,
      sortKey: (Map<String, dynamic> row) =>
          _text(row['departmentName']).toLowerCase(),
      cell: (BuildContext context, Map<String, dynamic> row) => Text(
        _text(row['departmentName']),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: context.dso.ink, fontWeight: FontWeight.w600),
      ),
    ),
    CatalogueColumn<Map<String, dynamic>>(
      id: 'pic',
      label: 'Person in charge',
      width: 220,
      flex: 2,
      sortKey: (Map<String, dynamic> row) =>
          _text(row['picName']).toLowerCase(),
      cell: (BuildContext context, Map<String, dynamic> row) => Text(
        _text(row['picName']),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    CatalogueColumn<Map<String, dynamic>>(
      id: 'userId',
      label: 'Staff code',
      width: 150,
      sortKey: (Map<String, dynamic> row) =>
          _text(row['picUserId']).toLowerCase(),
      cell: (BuildContext context, Map<String, dynamic> row) {
        final String userId = _text(row['picUserId']);
        return Text(
          userId.isEmpty ? '—' : userId,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: userId.isEmpty ? TextStyle(color: context.dso.muted) : null,
        );
      },
    ),
    CatalogueColumn<Map<String, dynamic>>(
      id: 'status',
      label: 'Status',
      width: 105,
      hideable: false,
      cell: (BuildContext context, Map<String, dynamic> row) =>
          const CatalogueStatusPill(
            label: 'Active',
            tone: CatalogueTone.success,
          ),
    ),
  ];

  Widget _buildWorkspace(
    AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
    List<Map<String, dynamic>> allRows,
    List<Map<String, dynamic>> visibleRows,
    List<CatalogueColumn<Map<String, dynamic>>> columns,
  ) {
    return CatalogueShortcuts(
      onEscape: () {
        if (_drawerOpen) {
          _requestCloseDrawer();
        } else {
          FocusManager.instance.primaryFocus?.unfocus();
        }
      },
      child: CatalogueWorkspace(
        title: 'Department PIC assignments',
        subtitle:
            'Retailer-specific contacts for each department · ${allRows.length} assignments',
        primaryAction: FilledButton.icon(
          onPressed: _can(PermissionAction.create) ? _openCreateDrawer : null,
          icon: const Icon(ScootIcons.add, size: 18),
          label: const Text('Add PIC'),
        ),
        toolbar: CatalogueToolbar<Map<String, dynamic>>(
          search: _searchController,
          searchFocus: _searchFocus,
          searchHint: 'Search retailers, departments, PICs',
          filters: const <CatalogueFilterMenu>[],
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
              'Showing ${visibleRows.length} of ${allRows.length}${_view.showingCloseMatches ? ' · no exact match, showing close spellings' : ''}',
          onClearFilters: () {
            _searchController.clear();
            _view.clearFilters();
          },
        ),
        body: _buildDirectoryBody(snapshot, allRows, visibleRows, columns),
        drawerOpen: _drawerOpen,
        onCloseDrawer: _requestCloseDrawer,
        drawer: _drawerOpen
            ? CatalogueDrawer(
                title: _editingDocId.isEmpty
                    ? 'Assign department PIC'
                    : 'Edit department PIC',
                dirty: _drawerDirty,
                onClose: _closeDrawer,
                body: _buildForm(),
                footer: <Widget>[
                  TextButton(
                    onPressed: _requestCloseDrawer,
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed:
                        _isSaving ||
                            _selectedDepartment == null ||
                            !_can(
                              _editingDocId.isEmpty
                                  ? PermissionAction.create
                                  : PermissionAction.edit,
                            )
                        ? null
                        : _save,
                    child: Text(_isSaving ? 'Saving...' : 'Save PIC'),
                  ),
                ],
              )
            : null,
      ),
    );
  }

  Widget _buildDirectoryBody(
    AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
    List<Map<String, dynamic>> allRows,
    List<Map<String, dynamic>> visibleRows,
    List<CatalogueColumn<Map<String, dynamic>>> columns,
  ) {
    if (snapshot.hasError) {
      return CatalogueError(
        message: userFacingError(
          snapshot.error!,
          action: 'load department PIC assignments',
        ),
      );
    }
    if (snapshot.connectionState == ConnectionState.waiting &&
        !snapshot.hasData) {
      return const CatalogueLoading();
    }
    if (allRows.isEmpty) {
      return CatalogueEmpty(
        title: 'No PIC assigned yet',
        message: 'Add a retailer-specific person in charge for a department.',
        action: _can(PermissionAction.create)
            ? FilledButton.icon(
                onPressed: _openCreateDrawer,
                icon: const Icon(ScootIcons.add, size: 18),
                label: const Text('Add PIC'),
              )
            : null,
      );
    }
    if (visibleRows.isEmpty) {
      return CatalogueNoResults(
        onClear: () {
          _searchController.clear();
          _view.clearFilters();
        },
      );
    }
    return CatalogueTable<Map<String, dynamic>>(
      rows: visibleRows,
      idOf: _rowId,
      labelOf: (Map<String, dynamic> row) =>
          '${_retailerGroup(row)}, ${_text(row['departmentName'])}, '
          '${_text(row['picName'])}',
      columns: columns,
      state: _view,
      groupOf: _retailerGroup,
      semanticsLabelPrefix: 'Department PIC assignment',
      selectable: false,
      onOpen: _edit,
      rowActions: (Map<String, dynamic> row) =>
          <CatalogueRowAction<Map<String, dynamic>>>[
            if (_canManageRow(row, PermissionAction.edit))
              CatalogueRowAction<Map<String, dynamic>>(
                label: 'Edit',
                icon: ScootIcons.edit,
                onPressed: _edit,
              ),
            if (_canManageRow(row, PermissionAction.delete))
              CatalogueRowAction<Map<String, dynamic>>(
                label: 'Delete',
                icon: ScootIcons.remove,
                destructive: true,
                onPressed: _delete,
              ),
          ],
    );
  }

  Widget _buildForm() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _retailersStream,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> retailersSnap,
          ) {
            final List<Map<String, dynamic>> retailers =
                List<Map<String, dynamic>>.from(
                  (retailersSnap.data ?? <Map<String, dynamic>>[]).where(
                    (Map<String, dynamic> retailer) =>
                        retailerInActorScope(widget.currentUser, retailer),
                  ),
                )..sort(
                  (Map<String, dynamic> a, Map<String, dynamic> b) =>
                      _retailerLabel(a).compareTo(_retailerLabel(b)),
                );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Assign a person-in-charge for a department within a specific retailer. This does not create a global department owner.',
                  style: TextStyle(
                    color: context.dso.muted,
                    height: 1.5,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 20),
                _stepLabel('1', 'Select Retailer'),
                const SizedBox(height: 8),
                InputDecorator(
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value:
                          retailers.any(
                            (Map<String, dynamic> retailer) =>
                                _retailerId(retailer) == _selectedRetailerId,
                          )
                          ? _selectedRetailerId
                          : null,
                      isExpanded: true,
                      hint: const Text('Choose retailer...'),
                      items: retailers.map((Map<String, dynamic> retailer) {
                        return DropdownMenuItem<String>(
                          value: _retailerId(retailer),
                          child: Text(
                            _retailerLabel(retailer),
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged:
                          (_editingDocId.isNotEmpty &&
                              widget.currentUser?.isAdmin != true)
                          ? null
                          : (String? value) {
                              if (value == null) return;
                              final Map<String, dynamic> retailer = retailers
                                  .firstWhere(
                                    (Map<String, dynamic> candidate) =>
                                        _retailerId(candidate) == value,
                                    orElse: () => <String, dynamic>{},
                                  );
                              setState(() {
                                _selectedRetailerId = value;
                                _selectedRetailerName = _retailerLabel(
                                  retailer,
                                );
                                _selectedDepartment = null;
                                _message = '';
                              });
                            },
                    ),
                  ),
                ),
                if (_selectedRetailerId != null) ...<Widget>[
                  const SizedBox(height: 20),
                  _stepLabel('2', 'Select Department'),
                  const SizedBox(height: 8),
                  _departmentDropdown(),
                ],
                if (_selectedDepartment != null) ...<Widget>[
                  const SizedBox(height: 20),
                  _stepLabel('3', 'PIC Details'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _picNameController,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'PIC full name *',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _picUserIdController,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Staff code / user ID (optional)',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  ),
                ],
                if (_message.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: _message.contains('success')
                          ? context.dso.successSoft
                          : context.dso.dangerSoft,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _message.contains('success')
                            ? context.dso.success.withValues(alpha: 0.4)
                            : context.dso.danger.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      _message,
                      style: TextStyle(
                        color: _message.contains('success')
                            ? _green
                            : context.dso.dangerText,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
    );
  }

  Widget _departmentDropdown() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _departmentsStream,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> departmentsSnap,
          ) {
            final List<String> deptList =
                (departmentsSnap.data ?? <Map<String, dynamic>>[])
                    .map((Map<String, dynamic> item) {
                      final String fromDepartmentName = _text(
                        item['departmentName'],
                      );
                      if (fromDepartmentName.isNotEmpty) {
                        return fromDepartmentName;
                      }
                      return _text(item['name']);
                    })
                    .where((String department) => department.isNotEmpty)
                    .toSet()
                    .toList()
                  ..sort();

            if (deptList.isEmpty) {
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.dso.warningSoft,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: context.dso.warning.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      ScootIcons.info,
                      size: 16,
                      color: context.dso.warningText,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'No master departments found. Create departments from Department Setup first.',
                        style: TextStyle(
                          fontSize: 13,
                          color: context.dso.warningText,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            return InputDecorator(
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: deptList.contains(_selectedDepartment)
                      ? _selectedDepartment
                      : null,
                  isExpanded: true,
                  hint: const Text('Choose department...'),
                  items: deptList.map((String department) {
                    return DropdownMenuItem<String>(
                      value: department,
                      child: Text(department, overflow: TextOverflow.ellipsis),
                    );
                  }).toList(),
                  onChanged: (String? value) {
                    setState(() {
                      _selectedDepartment = value;
                      _message = '';
                    });
                  },
                ),
              ),
            );
          },
    );
  }

  Widget _stepLabel(String number, String label) {
    return Row(
      children: <Widget>[
        Container(
          width: 22,
          height: 22,
          decoration: const BoxDecoration(
            color: _green,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              number,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: context.dso.body,
          ),
        ),
      ],
    );
  }

  static String _text(Object? value) {
    if (value == null) return '';
    final String text = value.toString().trim();
    return text.toLowerCase() == 'null' ? '' : text;
  }

  static String _retailerLabel(Map<String, dynamic> r) {
    for (final String key in <String>[
      'retailerName',
      'name',
      'retailer_name',
    ]) {
      final String v = _text(r[key]);
      if (v.isNotEmpty) return v;
    }
    return _text(r['docId']);
  }

  static String _retailerId(Map<String, dynamic> r) {
    for (final String key in <String>['retailerId', 'docId', 'retailer_id']) {
      final String v = _text(r[key]);
      if (v.isNotEmpty) return v;
    }
    return '';
  }
}
