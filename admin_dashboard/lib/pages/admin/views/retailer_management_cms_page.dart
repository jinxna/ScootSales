import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import '../../../utils/collection_rows.dart';

import '../../../app/build_flags.dart';
import '../../../models/conversation_outcome.dart';
import '../../../models/route_plan.dart';
import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../repositories/scoped_dashboard_repository.dart';
import '../../../services/outcome_review_service.dart';
import '../../../services/replenishment_service.dart';
import '../../../services/retailer_lifecycle_service.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/geo_field_utils.dart';
import '../../../utils/follow_up_dates.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/retailer_lifecycle.dart';
import '../../../utils/replenishment_comparison.dart';
import '../../../utils/retailer_bulk_assign.dart';
import '../../../utils/retailer_coordinate_edit.dart';
import '../../../utils/retailer_form_utils.dart';
import '../../../utils/retailer_memory.dart';
import '../../../utils/ai_data_freshness.dart';
import '../../../utils/safe_doc_id.dart';
import '../../../utils/user_facing_error.dart';
import '../../../widgets/cms_feedback.dart';
import '../../../widgets/ai_freshness_chip.dart';
import '../../../widgets/confirm_destructive_dialog.dart';
import '../../../widgets/shop_panel.dart';
import '../../../widgets/catalogue/catalogue_drawer.dart';
import '../../../widgets/catalogue/catalogue_workspace.dart';
import '../../../widgets/retailer_bulk_assign_list.dart';
import '../../../widgets/retailer_map/coordinate_edit_dialog.dart';
import '../../../widgets/retailer_map/retailer_map_models.dart';
import '../../../widgets/retailer_map/retailer_map_view.dart';
import '../widgets/cms_form_widgets.dart';
import '../widgets/cms_panel.dart';
import '../../../widgets/tip_text.dart';
import '../../../widgets/slow_loading.dart';

bool canWriteRetailers(UserProfile user) => user.isAdmin;

enum _RetailerView { list, map, coverage }

class RetailerManagementCmsPage extends StatefulWidget {
  const RetailerManagementCmsPage({
    super.key,
    required this.currentUser,
    required this.onOpenRoutePlanner,
    this.repository,
  });

  final UserProfile currentUser;
  final VoidCallback onOpenRoutePlanner;
  final CmsRepository? repository;

  @override
  State<RetailerManagementCmsPage> createState() =>
      _RetailerManagementCmsPageState();
}

class _RetailerManagementCmsPageState extends State<RetailerManagementCmsPage> {
  late final CmsRepository _repository = widget.repository ?? CmsRepository();
  final ScopedDashboardRepository _scopedReadRepository =
      ScopedDashboardRepository();
  final OutcomeReviewService _outcomeService = OutcomeReviewService();
  final ReplenishmentService _replenishmentService = ReplenishmentService();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _areaController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _contactController = TextEditingController();
  final TextEditingController _latController = TextEditingController();
  final TextEditingController _lngController = TextEditingController();
  final ValueNotifier<String?> _hoveredRetailerId = ValueNotifier<String?>(
    null,
  );
  final ValueNotifier<String?> _selectedRetailerId = ValueNotifier<String?>(
    null,
  );
  String _assignedSalesmanId = '';

  String _initialAssignedSalesmanId = '';
  String _status = 'Display';
  String? _editingId;
  Map<String, dynamic>? _editingOriginal;
  String _formSnapshot = '';
  final Set<String> _retiringIds = <String>{};
  bool _drawerOpen = false;
  bool _saving = false;
  final RetailerAssignmentWriter _assignmentWriter =
      FirestoreRetailerAssignmentWriter();
  List<RetailerSalesmanOption> _salesmanOptions = <RetailerSalesmanOption>[];
  String _branchId = '';
  List<Map<String, dynamic>> _branches = <Map<String, dynamic>>[];
  bool _branchesError = false;
  List<Map<String, dynamic>> _allRetailers = <Map<String, dynamic>>[];
  StreamSubscription<List<Map<String, dynamic>>>? _branchSubscription;
  _RetailerView _view = _RetailerView.list;
  Map<String, DateTime> _lastVisitByRetailer = <String, DateTime>{};
  Map<String, DateTime> _nextPlannedByRetailer = <String, DateTime>{};

  @override
  void initState() {
    super.initState();
    _loadNextPlannedVisits();
    _branchSubscription = _repository
        .watchCollection('branches', orderBy: 'branchName')
        .listen(
          (List<Map<String, dynamic>> rows) {
            if (!mounted) return;
            setState(() {
              _branches = rows;
              _branchesError = false;
            });
          },
          onError: (Object _) {
            if (!mounted) return;
            setState(() => _branchesError = true);
          },
        );
  }

  @override
  void dispose() {
    _branchSubscription?.cancel();
    _nameController.dispose();
    _areaController.dispose();
    _addressController.dispose();
    _contactController.dispose();
    _latController.dispose();
    _lngController.dispose();
    _hoveredRetailerId.dispose();
    _selectedRetailerId.dispose();
    super.dispose();
  }

  Future<void> _loadNextPlannedVisits() async {
    try {
      final ScopedDashboardReadResult result = await _scopedReadRepository
          .readDocuments(
            collection: 'route_plans',
            asOf: DateTime.now().add(const Duration(days: 56)),
            historyWindow: const Duration(days: 236),
            currentUser: widget.currentUser,
            salesmanField: 'salesmanCode',
            limit: 300,
            deadline: const Duration(seconds: 12),
            includeDocId: true,
          );
      final DateTime now = DateTime.now();
      final DateTime today = DateTime(now.year, now.month, now.day);
      final Map<String, DateTime> nextVisits = <String, DateTime>{};
      for (final Map<String, dynamic> row in result.documents) {
        if (_safeText(row['status'], fallback: '').toLowerCase() !=
                'published' ||
            row['isDemo'] == true) {
          continue;
        }
        final Object? rawDays = row['days'];
        if (rawDays is! List) continue;
        final List<Map<String, dynamic>> datedDays = rawDays
            .whereType<Map<dynamic, dynamic>>()
            .map((Map<dynamic, dynamic> day) => Map<String, dynamic>.from(day))
            .where((Map<String, dynamic> day) => _toDate(day['date']) != null)
            .toList(growable: false);
        if (datedDays.isEmpty) continue;
        final RoutePlan plan = RoutePlan.fromMap(
          _safeText(row['docId'] ?? row['planId'], fallback: ''),
          <String, dynamic>{...row, 'days': datedDays},
        );
        if (plan.isDemo || plan.status.toLowerCase() != 'published') continue;
        for (final RouteDay day in plan.days) {
          final DateTime date = DateTime(
            day.date.year,
            day.date.month,
            day.date.day,
          );
          if (date.isBefore(today)) continue;
          for (final RouteStop stop in day.stops) {
            final String retailerId = stop.retailerId.trim();
            if (retailerId.isEmpty) continue;
            final DateTime? previous = nextVisits[retailerId];
            if (previous == null || date.isBefore(previous)) {
              nextVisits[retailerId] = date;
            }
          }
        }
      }
      if (!mounted) return;
      setState(() => _nextPlannedByRetailer = nextVisits);
    } catch (_) {
      if (!mounted) return;
      setState(() => _nextPlannedByRetailer = <String, DateTime>{});
    }
  }

  bool get _canWrite => canWriteRetailers(widget.currentUser);

  bool get _needsBranchChoice =>
      widget.currentUser.isAdmin && _branches.isNotEmpty;

  Map<String, dynamic>? _openRetailerNamed(String docId, String name) {
    final String wanted = name.trim().toLowerCase();
    for (final Map<String, dynamic> row in _allRetailers) {
      if (_isHiddenRetailer(row)) continue;
      final String existingName = _retailerName(row).trim().toLowerCase();
      if (_safeText(row['docId'], fallback: '') == docId ||
          existingName == wanted) {
        return row;
      }
    }
    return null;
  }

  Future<void> _saveRetailer() async {
    if (_saving || !_formKey.currentState!.validate()) return;

    final String name = _nameController.text.trim();
    final bool creating = _editingId == null;
    final String docId =
        _editingId ?? safeDocId(name, fallbackPrefix: 'retailer');
    final Map<String, dynamic> coordinatePatch;
    try {
      coordinatePatch = retailerCoordinateEdit(
        latitudeText: _latController.text,
        longitudeText: _lngController.text,
        original: _editingOriginal,
      );
    } on FormatException catch (error) {
      if (!mounted) return;
      showCmsToast(context, error.message, isError: true);
      return;
    }
    if (creating) {
      final Map<String, dynamic>? existing = _openRetailerNamed(docId, name);
      if (existing != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('A retailer named "$name" already exists.'),
            backgroundColor: context.dso.dangerText,
            action: SnackBarAction(
              label: 'Open it',
              onPressed: () => _openEditDrawer(existing),
            ),
          ),
        );
        return;
      }
    }
    final bool savedCoordinatesPendingReview =
        coordinatePatch['coordinateStatus'] == 'candidate';
    final String branchId = widget.currentUser.isBranchManager
        ? widget.currentUser.branchId.trim()
        : _branchId.trim();
    final Map<String, dynamic> data = <String, dynamic>{
      'retailerId': docId,
      'retailerName': name,
      'area': _areaController.text.trim(),
      'address': _addressController.text.trim(),
      'contactPerson': _contactController.text.trim(),
      if (!creating && _assignedSalesmanId != _initialAssignedSalesmanId)
        ...retailerAssignmentPayload(_assignedSalesmanId)
      else
        'assignedSalesmanId': _assignedSalesmanId,
      if (branchId.isNotEmpty) 'branchId': branchId,
      ...coordinatePatch,
      'status': _status == 'Hide' ? 'hidden' : 'active',
      'stockListVisible': _status != 'Hide',
    };
    setState(() => _saving = true);
    try {
      if (creating) {
        await _repository.createDocumentIfAbsent(
          collectionName: 'retailers',
          docId: docId,
          data: <String, dynamic>{
            ...data,
            'createdAt': FieldValue.serverTimestamp(),
          },
          duplicateMessage:
              'a retailer with this name already exists (it may have been '
              'removed earlier). Search the directory, or use a different '
              'name.',
        );
      } else {
        await _repository.upsertDocument(
          collectionName: 'retailers',
          docId: docId,
          data: data,
        );
      }
      if (!mounted) return;
      _clearForm();
      showCmsToast(
        context,
        !savedCoordinatesPendingReview
            ? (creating ? 'Retailer added.' : 'Retailer updated.')
            : 'Retailer saved. Coordinates were recorded as a candidate — '
                  'open Coordinate Review to verify them for routing.',
      );
    } catch (error) {
      if (!mounted) return;
      showCmsToast(
        context,
        userFacingError(error, action: 'save the retailer'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _clearForm({bool openDrawer = false}) {
    setState(() {
      _editingId = null;
      _editingOriginal = null;
      _nameController.clear();
      _areaController.clear();
      _addressController.clear();
      _contactController.clear();
      _latController.clear();
      _lngController.clear();
      _assignedSalesmanId = '';
      _initialAssignedSalesmanId = '';
      _branchId = '';
      _status = 'Display';
      _drawerOpen = openDrawer;
      _formSnapshot = openDrawer ? _formSignature() : '';
    });
  }

  String _formSignature() => <String>[
    _nameController.text,
    _areaController.text,
    _addressController.text,
    _contactController.text,
    _latController.text,
    _lngController.text,
    _assignedSalesmanId,
    _branchId,
    _status,
  ].join('\u0000');

  bool get _dirty => _drawerOpen && _formSignature() != _formSnapshot;

  void _openCreateDrawer() {
    if (!_canWrite) return;
    closeCatalogueDrawer(
      context,
      dirty: _dirty,
      onClose: () => _clearForm(openDrawer: true),
    );
  }

  void _requestCloseDrawer() =>
      closeCatalogueDrawer(context, dirty: _dirty, onClose: () => _clearForm());

  void _openEditDrawer(Map<String, dynamic> retailer) {
    if (!_canWrite) return;
    closeCatalogueDrawer(
      context,
      dirty: _dirty,
      onClose: () => _fillFormFromRetailer(retailer),
    );
  }

  void _fillFormFromRetailer(Map<String, dynamic> retailer) {
    setState(() {
      _editingId = retailer['docId'] as String?;
      _editingOriginal = Map<String, dynamic>.from(retailer);
      _nameController.text = _retailerName(retailer) == '-'
          ? ''
          : _retailerName(retailer);
      _areaController.text = retailer['area'] as String? ?? '';
      _addressController.text = retailer['address'] as String? ?? '';
      _contactController.text = retailer['contactPerson'] as String? ?? '';
      _assignedSalesmanId = _safeText(
        retailer['assignedSalesmanId'] ??
            retailer['salesmanId'] ??
            retailer['salesman_id'],
        fallback: '',
      );
      _initialAssignedSalesmanId = _assignedSalesmanId;
      _branchId = _safeText(
        retailer['branchId'] ?? retailer['branch_id'],
        fallback: '',
      );
      final point = readLatLng(retailer);
      _latController.text = point?.latitude.toString() ?? '';
      _lngController.text = point?.longitude.toString() ?? '';
      _status = normaliseRetailerDisplayStatus(
        retailer['status'],
        visible: retailer['visible'],
      );
      _drawerOpen = true;
      _formSnapshot = _formSignature();
    });
  }

  Future<void> _reviewCoordinates(
    RetailerMapPoint point,
    Map<String, dynamic> retailer,
  ) async {
    if (!_canWrite) return;
    final CoordinateEditOutcome? outcome = await showCoordinateEditDialog(
      context,
      retailer: retailer,
      retailerName: point.name,
      address: point.address,
      initialLatitude: point.point?.latitude.toStringAsFixed(6) ?? '',
      initialLongitude: point.point?.longitude.toStringAsFixed(6) ?? '',
      reviewerUid: widget.currentUser.uid ?? '',
    );
    if (outcome == null || !mounted) return;
    try {
      await _repository.upsertDocument(
        collectionName: 'retailers',
        docId: point.id,
        data: outcome.payload,
      );
      if (!mounted) return;
      showCmsToast(
        context,
        outcome.verified
            ? 'Coordinates saved and verified for ${point.name}.'
            : 'Candidate coordinates saved for ${point.name}; still needs review.',
      );
    } catch (error) {
      if (!mounted) return;
      showCmsToast(
        context,
        userFacingError(error, action: 'save the coordinates'),
        isError: true,
      );
    }
  }

  bool _isSalesmanRole(Object? value) {
    final String role = _safeText(
      value,
      fallback: '',
    ).toLowerCase().replaceAll('-', '_').replaceAll(' ', '_');
    return role.contains('sales') ||
        role.contains('representative') ||
        role == 'salesman';
  }

  String _retailerName(Map<String, dynamic> retailer) {
    return _safeText(
      retailer['retailerName'] ??
          retailer['retailer_name'] ??
          retailer['name'] ??
          retailer['martName'] ??
          retailer['customerName'] ??
          retailer['docId'],
      fallback: '-',
    );
  }

  String _safeText(Object? value, {required String fallback}) {
    if (value == null) return fallback;
    final String text = value.toString().trim();
    return text.isEmpty || text.toLowerCase() == 'null' ? fallback : text;
  }

  bool _isDemoRetailer(Map<String, dynamic> retailer) =>
      isDemoRetailerRecord(retailer);

  bool _isRetiredRetailer(Map<String, dynamic> retailer) {
    final String status = _safeText(
      retailer['status'] ?? retailer['retailerStatus'],
      fallback: '',
    ).toLowerCase();
    return status == 'retired' || retailer['retiredAt'] != null;
  }

  bool _isHiddenRetailer(Map<String, dynamic> retailer) =>
      _isDemoRetailer(retailer) || _isRetiredRetailer(retailer);

  String _retailerId(Map<String, dynamic> retailer) =>
      _safeText(retailer['retailerId'] ?? retailer['docId'], fallback: '');

  Future<void> _retireRetailer(Map<String, dynamic> retailer) async {
    if (!_canWrite) return;
    final String id = _retailerId(retailer);
    if (id.isEmpty || _retiringIds.contains(id)) return;
    final String name = _retailerName(retailer);
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Remove retailer?',
      message:
          'Remove $name from operational retailer lists? Historical orders and visits will be kept.',
      confirmLabel: 'Remove',
    );
    if (!confirmed || !mounted) return;
    setState(() => _retiringIds.add(id));
    try {
      final bool changed = await _repository.retireRetailer(
        retailerId: id,
        actor: widget.currentUser,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            changed
                ? '$name removed from operational lists.'
                : '$name is already removed.',
          ),
          backgroundColor: const Color(0xFF12B76A),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      showCmsToast(
        context,
        userFacingError(error, action: 'remove $name'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _retiringIds.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _repository.watchCollection('users', orderBy: 'name'),
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> userSnapshot,
          ) {
            final List<Map<String, dynamic>> salesmen =
                (userSnapshot.data ?? <Map<String, dynamic>>[])
                    .where(
                      (Map<String, dynamic> user) => _isSalesmanRole(
                        user['role'] ?? user['user_group'] ?? user['roleLabel'],
                      ),
                    )
                    .toList();

            final RetailerSalesmanField salesmanField = retailerSalesmanField(
              salesmen,
              _assignedSalesmanId,
            );
            _salesmanOptions = salesmanField.options;
            final String? unmatchedAssignment =
                salesmanField.unmatchedAssignment;
            final List<DropdownMenuItem<String>> salesmanItems =
                <DropdownMenuItem<String>>[
                  const DropdownMenuItem<String>(
                    value: '',
                    child: Text('Not assigned'),
                  ),
                  for (final RetailerSalesmanOption option
                      in salesmanField.options)
                    DropdownMenuItem<String>(
                      value: option.storageValue,
                      child: Text(option.label),
                    ),
                  if (unmatchedAssignment != null)
                    DropdownMenuItem<String>(
                      value: unmatchedAssignment,
                      child: Text(
                        '$unmatchedAssignment (not in the current user list)',
                      ),
                    ),
                ];

            return CatalogueWorkspace(
              title: 'Retailers',
              subtitle: _allRetailers.isEmpty
                  ? null
                  : '${_allRetailers.where((Map<String, dynamic> r) => !_isHiddenRetailer(r)).length} retailers',
              primaryAction: _canWrite
                  ? FilledButton.icon(
                      onPressed: _openCreateDrawer,
                      icon: const Icon(ScootIcons.add, size: 18),
                      label: const Text('Add retailer'),
                    )
                  : const Text(
                      'View only',
                      key: ValueKey<String>('retailer-view-only'),
                    ),
              viewSwitcher: <Widget>[
                Builder(
                  builder: (BuildContext context) {
                    final bool narrow = MediaQuery.sizeOf(context).width < 600;
                    return SegmentedButton<_RetailerView>(
                      style: narrow
                          ? SegmentedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            )
                          : null,
                      segments: <ButtonSegment<_RetailerView>>[
                        ButtonSegment<_RetailerView>(
                          value: _RetailerView.list,
                          label: const Text('List'),
                          icon: narrow ? null : const Icon(ScootIcons.layers),
                        ),
                        ButtonSegment<_RetailerView>(
                          value: _RetailerView.map,
                          label: const Text('Map'),
                          icon: narrow ? null : const Icon(ScootIcons.map),
                        ),
                        ButtonSegment<_RetailerView>(
                          value: _RetailerView.coverage,
                          label: const Text('Coverage'),
                          icon: narrow ? null : const Icon(ScootIcons.reports),
                        ),
                      ],
                      selected: <_RetailerView>{_view},
                      showSelectedIcon: false,
                      onSelectionChanged: (Set<_RetailerView> selection) =>
                          setState(() => _view = selection.single),
                    );
                  },
                ),
              ],
              toolbar: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  _view == _RetailerView.map
                      ? 'Select a retailer to review location and visit dates.'
                      : _view == _RetailerView.coverage
                      ? 'Lifecycle stage and coverage of every operational retailer.'
                      : 'Operational retailers only. Demo and retired records stay out of this workspace.',
                  style: TextStyle(fontSize: 12.5, color: context.dso.muted),
                ),
              ),
              drawer: _buildRetailerForm(salesmanField, salesmanItems),
              drawerOpen: _drawerOpen,
              onCloseDrawer: _requestCloseDrawer,
              body: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  const double minHeight = 520;
                  final Widget content = Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: Offstage(
                          offstage: _view == _RetailerView.coverage,
                          child: _buildRetailerDirectory(),
                        ),
                      ),
                      Positioned.fill(
                        child: Offstage(
                          offstage: _view != _RetailerView.coverage,
                          child: _CoverageLifecyclePanel(
                            currentUser: widget.currentUser,
                            repository: _repository,
                            isDemoRetailer: _isHiddenRetailer,
                            onLastVisitsLoaded: (Map<String, DateTime> visits) {
                              if (!mounted) return;
                              setState(() => _lastVisitByRetailer = visits);
                            },
                          ),
                        ),
                      ),
                    ],
                  );
                  if (constraints.maxHeight >= minHeight) return content;
                  return SingleChildScrollView(
                    child: SizedBox(height: minHeight, child: content),
                  );
                },
              ),
            );
          },
    );
  }

  Widget _buildRetailerForm(
    RetailerSalesmanField salesmanField,
    List<DropdownMenuItem<String>> salesmanItems,
  ) {
    return CatalogueDrawer(
      title: _editingId == null ? 'Add Retailer' : 'Edit Retailer',
      dirty: _dirty,
      onClose: _clearForm,
      footer: <Widget>[
        PrimaryCmsButton(
          label: _editingId == null ? 'Save Retailer' : 'Update Retailer',
          isPending: _saving,
          onTap: _saveRetailer,
        ),
        const SizedBox(width: 10),
        OutlinedButton(
          onPressed: _saving ? null : () => _clearForm(openDrawer: true),
          child: const Text('Reset'),
        ),
      ],
      body: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _field(_nameController, 'Retailer Name', required: true),
            const SizedBox(height: 16),
            _field(_areaController, 'Area'),
            const SizedBox(height: 16),
            _field(_addressController, 'Address', required: true, maxLines: 2),
            const SizedBox(height: 16),
            _field(_contactController, 'Contact Person'),
            const SizedBox(height: 16),
            if (widget.currentUser.isAdmin) ...<Widget>[
              const CmsFormLabel(label: 'Branch'),
              DropdownButtonFormField<String>(
                key: ValueKey<String>('retailer-branch-$_branchId'),
                initialValue:
                    _branches.any(
                      (Map<String, dynamic> b) => b['docId'] == _branchId,
                    )
                    ? _branchId
                    : null,
                hint: Text(
                  _branches.isEmpty
                      ? 'No branches yet - create one in Branches first'
                      : 'Select a branch',
                ),
                items: <DropdownMenuItem<String>>[
                  for (final Map<String, dynamic> branch in _branches)
                    DropdownMenuItem<String>(
                      value: '${branch['docId']}',
                      child: Text('${branch['branchName'] ?? branch['docId']}'),
                    ),
                ],
                validator: (String? value) =>
                    _needsBranchChoice && (value == null || value.isEmpty)
                    ? 'Choose the branch this retailer belongs to'
                    : null,
                onChanged: (String? value) =>
                    setState(() => _branchId = value ?? ''),
              ),
              if (_branchesError)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Branches could not be loaded.',
                    key: const ValueKey<String>('retailer-branches-error'),
                    style: ScootType.caption.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
            ],
            const CmsFormLabel(label: 'Assigned Salesman'),
            DropdownButtonFormField<String>(
              initialValue: salesmanField.selectedValue,
              items: salesmanItems,
              onChanged: (String? value) =>
                  setState(() => _assignedSalesmanId = value ?? ''),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 16,
              children: <Widget>[
                SizedBox(
                  width: 240,
                  child: _field(_latController, 'GPS Latitude'),
                ),
                SizedBox(
                  width: 240,
                  child: _field(_lngController, 'GPS Longitude'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const CmsFormLabel(label: 'Status'),
            CmsDropdown(
              value: _status,
              items: const <String>['Display', 'Hide'],
              onChanged: (String? value) =>
                  setState(() => _status = value ?? 'Display'),
              width: double.infinity,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _retryRetailers() async {
    await _repository.resetCollectionStream(
      'retailers',
      orderBy: 'retailerName',
    );
    if (mounted) setState(() {});
  }

  Widget _buildRetailerDirectory() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _repository.watchCollection('retailers', orderBy: 'retailerName'),
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
          ) {
            final List<Map<String, dynamic>> all =
                snapshot.data ?? <Map<String, dynamic>>[];
            _allRetailers = all;
            final List<Map<String, dynamic>> retailers = all
                .where((Map<String, dynamic> row) => !_isHiddenRetailer(row))
                .toList(growable: false);
            final Map<String, Map<String, dynamic>> rowsById =
                <String, Map<String, dynamic>>{
                  for (final Map<String, dynamic> row in retailers)
                    _safeText(
                      row['docId'] ?? row['retailerId'] ?? row['id'],
                      fallback: '',
                    ): row,
                };

            if (_view != _RetailerView.map) {
              final Widget content;
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                content = SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(ScootSpace.lg),
                  child: ScootLoadingState(
                    onRetry: _retryRetailers,
                    semanticLabel: 'Loading retailers',
                    skeleton: Column(
                      children: <Widget>[
                        for (int i = 0; i < 6; i++)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: ScootSkeleton(height: 40),
                          ),
                      ],
                    ),
                  ),
                );
              } else if (snapshot.hasError && !snapshot.hasData) {
                content = Center(
                  child: ScootErrorState(
                    message:
                        'Retailers could not be loaded. Check your connection, then try again.',
                    onRetry: _retryRetailers,
                  ),
                );
              } else if (all.isEmpty) {
                content = const Center(child: Text('No retailers yet.'));
              } else if (retailers.isEmpty) {
                content = const Center(
                  child: Text('No operational retailers are available yet.'),
                );
              } else {
                content = LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) {
                    final bool stacked = box.maxWidth < _tableMinWidth;
                    return RetailerBulkAssignList(
                      retailers: retailers,
                      options: _salesmanOptions,
                      writer: _assignmentWriter,
                      canEdit: _canWrite,
                      isRetired: _isRetiredRetailer,
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      rowGap: 0,
                      header: stacked ? null : _tableHeader(),
                      cardBuilder:
                          (BuildContext context, Map<String, dynamic> r) =>
                              _retailerRow(r, stacked: stacked),
                    );
                  },
                );
              }
              return CmsPanel(
                title: 'Retailer directory',
                trailing: Text(
                  '${retailers.length} shown',
                  style: ScootType.small.copyWith(
                    color: ScootColors.of(context).muted,
                  ),
                ),
                child: content,
              );
            }

            final List<RetailerMapPoint> points = retailers
                .map(RetailerMapPoint.fromRow)
                .toList(growable: false);
            return CmsPanel(
              title: 'Retailer Map',
              child: RetailerMapView(
                points: points,
                hoveredId: _hoveredRetailerId,
                selectedId: _selectedRetailerId,
                lastVisitByRetailer: _lastVisitByRetailer,
                nextPlannedByRetailer: _nextPlannedByRetailer,
                onReviewCoordinates: _canWrite
                    ? (RetailerMapPoint point) async {
                        final Map<String, dynamic>? retailer =
                            rowsById[point.id];
                        if (retailer != null) {
                          await _reviewCoordinates(point, retailer);
                        }
                      }
                    : null,
                onOpenRoutePlanner: widget.onOpenRoutePlanner,
              ),
            );
          },
    );
  }

  static const double _tableMinWidth = 1100;
  static const double _rowHeight = 48;
  static const double _actionsWidth = 340;

  Widget _tableHeader() {
    final ScootColors c = ScootColors.of(context);
    final TextStyle style = ScootType.tableHead.copyWith(
      color: c.tableHeadText,
    );
    Widget label(String text, int flex) => Expanded(
      flex: flex,
      child: Text(text, style: style),
    );
    return Container(
      height: ScootSize.tableHeader,
      padding: const EdgeInsets.only(left: 3),
      decoration: BoxDecoration(
        color: c.tableHead,
        border: Border(bottom: BorderSide(color: c.hair)),
      ),
      child: Row(
        children: <Widget>[
          label('Name', 4),
          label('Branch', 2),
          label('Salesperson', 3),
          label('Status', 2),
          label('Last visit', 2),
          SizedBox(
            width: _actionsWidth,
            child: Text('Actions', style: style),
          ),
        ],
      ),
    );
  }

  String _branchLabel(Map<String, dynamic> retailer) {
    final String id = _safeText(
      retailer['branchId'] ?? retailer['branch_id'],
      fallback: '',
    );
    if (id.isEmpty) return '-';
    for (final Map<String, dynamic> branch in _branches) {
      if ('${branch['docId']}' == id) {
        return _safeText(branch['branchName'], fallback: id);
      }
    }
    return id;
  }

  Widget _retailerRow(Map<String, dynamic> retailer, {required bool stacked}) {
    final String id = _retailerId(retailer);
    final DateTime? lastVisit = _lastVisitByRetailer[id];
    final DateTime? nextVisit = _nextPlannedByRetailer[id];
    final String storedStatus = _safeText(
      retailer['status'],
      fallback: '',
    ).toLowerCase();
    final bool hidden =
        normaliseRetailerDisplayStatus(
          storedStatus,
          visible: retailer['visible'],
        ) ==
        'Hide';
    final bool hiddenByDashboard =
        storedStatus == 'hidden' || storedStatus == 'hide';
    final ScootColors c = ScootColors.of(context);
    final TextStyle text = ScootType.body.copyWith(color: c.ink);
    final TextStyle caption = ScootType.caption.copyWith(color: c.muted);
    final String name = _retailerName(retailer);
    final String branch = _branchLabel(retailer);
    final String storedSalesperson = _safeText(
      retailer['assignedSalesmanName'] ??
          retailer['salesmanName'] ??
          retailer['assignedSalesmanId'],
      fallback: 'Not assigned',
    );
    final RetailerSalesmanOption? assigned =
        findRetailerSalesmanOption(
          _salesmanOptions,
          retailer['assignedSalesmanId'] ??
              retailer['salesmanId'] ??
              retailer['salesman_id'],
        ) ??
        findRetailerSalesmanOption(_salesmanOptions, storedSalesperson);
    final String salesperson = assigned?.label ?? storedSalesperson;
    final String lastVisitText = lastVisit == null
        ? 'Not recorded'
        : _formatDate(lastVisit);
    final String nextVisitText =
        'Next planned visit: ${nextVisit == null ? 'Not planned' : _formatDate(nextVisit)}';
    final Widget status = ScootBadge(
      label: !hidden
          ? 'Active'
          : hiddenByDashboard || storedStatus.isEmpty
          ? 'Hidden'
          : 'Inactive',
      tone: hidden ? ScootTone.neutral : ScootTone.success,
    );
    final List<Widget> actions = <Widget>[
      if (!isBasicEdition) ...<Widget>[
        _rowAction(
          'Shop panel',
          name,
          () => showShopPanel(
            context,
            currentUser: widget.currentUser,
            retailerId: id,
            retailerName: name,
          ),
        ),
        _rowAction(
          'Memory',
          name,
          () => _showRetailerMemoryDialog(
            context,
            retailerId: id,
            retailerName: name,
          ),
        ),
        _rowAction(
          'Replenishment',
          name,
          () => _showReplenishmentDialog(
            context,
            retailerId: id,
            retailerName: name,
          ),
        ),
      ],
      if (!_canWrite)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            'View only',
            key: ValueKey<String>('retailer-card-view-only'),
          ),
        ),
      if (_canWrite) _rowAction('Edit', name, () => _openEditDrawer(retailer)),
      if (_canWrite)
        _rowAction(
          'Remove',
          name,
          _retiringIds.contains(id) ? null : () => _retireRetailer(retailer),
        ),
    ];
    Widget cell(int flex, String value, {TextStyle? style}) => Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: TipText(value, style: style ?? text, maxLines: 1),
      ),
    );
    Widget card() => Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  name,
                  style: text.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              status,
            ],
          ),
          const SizedBox(height: 4),
          Text('Branch: $branch', style: caption),
          Text('Salesperson: $salesperson', style: caption),
          Text('Last visit: $lastVisitText', style: caption),
          Text(nextVisitText, style: caption),
          const SizedBox(height: 4),
          Wrap(spacing: 4, runSpacing: 4, children: actions),
        ],
      ),
    );
    Widget tableRow() => Row(
      children: <Widget>[
        cell(4, name, style: text.copyWith(fontWeight: FontWeight.w600)),
        cell(2, branch),
        cell(3, salesperson),
        Expanded(
          flex: 2,
          child: Align(alignment: Alignment.centerLeft, child: status),
        ),
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  lastVisitText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text,
                ),
                Text(
                  nextVisitText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: caption,
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          width: _actionsWidth,
          child: Row(children: actions),
        ),
      ],
    );
    return ValueListenableBuilder<String?>(
      valueListenable: _selectedRetailerId,
      builder: (BuildContext context, String? selectedId, Widget? _) {
        final bool selected = selectedId != null && selectedId == id;
        return InkWell(
          onTap: () => _selectedRetailerId.value = selected ? null : id,
          child: Container(
            height: stacked ? null : _rowHeight,
            decoration: BoxDecoration(
              color: selected ? c.brandTint : null,
              border: Border(
                left: BorderSide(
                  color: selected ? c.brand : Colors.transparent,
                  width: 3,
                ),
                bottom: BorderSide(color: c.hair),
              ),
            ),
            child: stacked ? card() : tableRow(),
          ),
        );
      },
    );
  }

  Widget _rowAction(String label, String name, VoidCallback? onPressed) =>
      TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          label,
          semanticsLabel: '$label $name',
          style: ScootType.smallStrong,
        ),
      );

  Future<_RetailerMemoryData> _loadRetailerMemory(String retailerId) async {
    final Map<String, dynamic>? snapshot = await _outcomeService
        .loadRetailerMemorySnapshot(retailerId);
    if (snapshot != null) {
      return _RetailerMemoryData(
        source: _MemorySource.ai,
        snapshot: snapshot,
        productNames: await _productNameIndex().catchError(
          (Object _) => <String, String>{},
        ),
      );
    }
    final List<ConversationOutcome>? outcomes = await _outcomeService
        .loadRetailerOutcomes(widget.currentUser, retailerId: retailerId);
    if (outcomes == null) {
      return const _RetailerMemoryData(source: _MemorySource.error);
    }
    final Iterable<RetailerOutcomeEvent> events = outcomes
        .where(
          (ConversationOutcome outcome) =>
              !outcome.qualityFlags.contains('invalid_reason_code'),
        )
        .map(
          (ConversationOutcome outcome) => RetailerOutcomeEvent(
            reasonCode: outcome.reasonCode,
            replacementProductId: outcome.replacementProductId,
            productId: outcome.productId,
            productName: outcome.productName,
            issueKey: outcome.issueKey,
            submittedAt: outcome.submittedAt,
            isDemo: outcome.isDemo,
          ),
        );
    return _RetailerMemoryData(
      source: _MemorySource.live,
      live: deriveRetailerMemory(events, now: DateTime.now()),
    );
  }

  Future<void> _showRetailerMemoryDialog(
    BuildContext context, {
    required String retailerId,
    required String retailerName,
  }) {
    final Future<_RetailerMemoryData> future = retailerId.isEmpty
        ? Future<_RetailerMemoryData>.value(
            const _RetailerMemoryData(source: _MemorySource.error),
          )
        : _loadRetailerMemory(retailerId);
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Retailer memory — $retailerName'),
        content: SizedBox(
          width: 420,
          child: FutureBuilder<_RetailerMemoryData>(
            future: future,
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<_RetailerMemoryData> snapshot,
                ) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 120),
                      child: SlowLoading(),
                    );
                  }
                  final _RetailerMemoryData? data = snapshot.data;
                  if (data == null || data.source == _MemorySource.error) {
                    return const Text(
                      'Could not load this retailer\'s memory. Check your connection and try again.',
                    );
                  }
                  return SingleChildScrollView(
                    child: data.source == _MemorySource.ai
                        ? _aiMemoryContent(data.snapshot!, data.productNames)
                        : _liveMemoryContent(data.live!),
                  );
                },
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<Map<String, String>> _productNameIndex() async {
    final List<Map<String, dynamic>> products = await _repository
        .getCollectionOnce('products', limit: 500);
    final Map<String, String> index = <String, String>{};
    for (final Map<String, dynamic> product in products) {
      final String id = _safeText(
        product['productId'] ?? product['docId'],
        fallback: '',
      );
      final String name = _safeText(
        product['productName'] ?? product['itemName'],
        fallback: '',
      );
      if (id.isNotEmpty && name.isNotEmpty) index[id] = name;
    }
    return index;
  }

  Future<_ReplenishmentData> _loadReplenishment(String retailerId) async {
    final List<String> failedSources = <String>[];
    final Future<Map<String, String>> productNamesRead = _productNameIndex();
    final Future<List<Map<String, dynamic>>> ordersRead = _replenishmentService
        .loadRetailerOrders(
          widget.currentUser,
          retailerId,
          failedSources: failedSources,
        );
    final Future<Map<String, dynamic>?> briefRead = _replenishmentService
        .loadVisitBriefSnapshot(
          widget.currentUser,
          retailerId,
          failedSources: failedSources,
        );
    productNamesRead.ignore();
    ordersRead.ignore();
    briefRead.ignore();
    final Map<String, String> productNames = await productNamesRead;
    final List<Map<String, dynamic>> orders = await ordersRead;
    final Map<String, dynamic>? brief = await briefRead;
    if (failedSources.isNotEmpty) {
      return const _ReplenishmentData(
        source: _ReplenishmentSource.error,
        rows: <ReplenishmentComparisonRow>[],
        productNames: <String, String>{},
      );
    }
    if (brief != null) {
      final DateTime today = DateTime.parse(kualaLumpurDateKey());
      final List<Map<String, dynamic>> suggestions =
          (brief['replenishment'] as List? ?? const <dynamic>[])
              .whereType<Map>()
              .map((Map row) => row.cast<String, dynamic>())
              .toList();
      final List<Map<String, dynamic>> readinessRows = <Map<String, dynamic>>[];
      for (final Object? raw
          in brief['replenishmentReadiness'] as List? ?? const <dynamic>[]) {
        if (raw is! Map) continue;
        final Map<String, dynamic> row = Map<String, dynamic>.from(raw);
        final Map<String, dynamic> forecast = row['forecast'] is Map
            ? Map<String, dynamic>.from(row['forecast'] as Map)
            : const <String, dynamic>{};
        final Map<String, String> readiness = _weeklyForecastReadiness(
          forecast,
          today: today,
        );
        final bool nowStale = readiness['status'] == 'stale';
        readinessRows.add(<String, dynamic>{
          ...row,
          'suggestionStatus': readiness['status'] == 'usable'
              ? row['suggestionStatus']
              : readiness['status'],
          'rationale': nowStale
              ? readiness['message']
              : row['rationale'] ?? readiness['message'],
        });
      }
      final List<Map<String, dynamic>> currentSuggestions =
          <Map<String, dynamic>>[];
      for (final Map<String, dynamic> suggestion in suggestions) {
        final Map<String, dynamic> forecast = suggestion['forecast'] is Map
            ? Map<String, dynamic>.from(suggestion['forecast'] as Map)
            : const <String, dynamic>{};
        final Map<String, String> readiness = _weeklyForecastReadiness(
          forecast,
          today: today,
        );
        final int quantity = (suggestion['suggestedQty'] as num?)?.toInt() ?? 0;
        if (readiness['status'] == 'usable' &&
            suggestion['suggestionStatus'] == 'suggested' &&
            quantity > 0) {
          currentSuggestions.add(suggestion);
        } else {
          final String readinessStatus = readiness['status']!;
          readinessRows.add(<String, dynamic>{
            ...suggestion,
            'suggestedQty': null,
            'suggestionStatus': readinessStatus,
            'rationale': readinessStatus == 'stale'
                ? readiness['message']
                : _safeText(suggestion['rationale'], fallback: '').isNotEmpty
                ? suggestion['rationale']
                : readiness['message'],
          });
        }
      }
      final List<ReplenishmentComparisonRow> rows =
          deriveReplenishmentComparison(
            retailerId: retailerId,
            suggestions: currentSuggestions,
            orders: orders,
          );
      return _ReplenishmentData(
        source: _ReplenishmentSource.ai,
        rows: rows,
        productNames: <String, String>{
          ...productNames,
          for (final Map<String, dynamic> suggestion in currentSuggestions)
            if (_safeText(suggestion['productName'], fallback: '').isNotEmpty)
              _safeText(suggestion['productId'], fallback: ''): _safeText(
                suggestion['productName'],
                fallback: '',
              ),
        },
        readinessRows: readinessRows,
        generatedAt: aiDataTimestamp(brief),
        hasAiData: true,
        hasMissingTimestamp: aiDataTimestamp(brief) == null,
      );
    }

    final List<Map<String, dynamic>> patterns = await _replenishmentService
        .loadRetailerItemPatterns(
          widget.currentUser,
          retailerId,
          failedSources: failedSources,
        );
    if (failedSources.isNotEmpty) {
      return const _ReplenishmentData(
        source: _ReplenishmentSource.error,
        rows: <ReplenishmentComparisonRow>[],
        productNames: <String, String>{},
      );
    }
    final DateTime today = DateTime.parse(kualaLumpurDateKey());
    final List<Map<String, dynamic>> readinessRows = patterns
        .map((Map<String, dynamic> pattern) {
          final Map<String, String> readiness =
              _weeklyForecastReadiness(<String, dynamic>{
                'status': pattern['forecastStatus'],
                'periodStart': pattern['forecastPeriodStart'],
                'dataCutoff': pattern['forecastDataCutoff'],
                'point': pattern['forecastNextWeek'],
                'pointSemantics': pattern['forecastSemantics'],
                'modelVersion': pattern['forecastModelsVersion'],
              }, today: today);
          final String forecastStatus = readiness['status']!;
          final bool usable = forecastStatus == 'usable';
          return <String, dynamic>{
            'productId': pattern['productId'],
            'productName': pattern['productName'],
            'packingSize': pattern['packingSize'],
            'unitOfMeasure': pattern['unitOfMeasure'],
            'suggestionStatus': usable ? 'awaiting_brief' : forecastStatus,
            'rationale': usable
                ? 'Weekly forecast is ready. An AI visit brief is needed before an order quantity is shown.'
                : readiness['message'],
            'forecast': <String, dynamic>{
              'status': forecastStatus == 'usable'
                  ? 'ok'
                  : forecastStatus == 'stale'
                  ? 'stale'
                  : forecastStatus,
              'periodStart': pattern['forecastPeriodStart'],
              'dataCutoff': pattern['forecastDataCutoff'],
              'point': pattern['forecastNextWeek'],
              'pointSemantics': pattern['forecastSemantics'],
              'modelVersion': pattern['forecastModelsVersion'],
              'demandClass': pattern['demandClassification'],
            },
          };
        })
        .toList(growable: false);
    return _ReplenishmentData(
      source: _ReplenishmentSource.live,
      rows: const <ReplenishmentComparisonRow>[],
      productNames: productNames,
      readinessRows: readinessRows,
      generatedAt: patterns
          .map(aiDataTimestamp)
          .whereType<DateTime>()
          .fold<DateTime?>(
            null,
            (DateTime? newest, DateTime candidate) =>
                newest == null || candidate.isAfter(newest)
                ? candidate
                : newest,
          ),
      hasAiData: patterns.isNotEmpty,
      hasMissingTimestamp: patterns.any(
        (Map<String, dynamic> row) => aiDataTimestamp(row) == null,
      ),
      message:
          'No visit brief has been published for this shop. Forecast readiness is shown below.',
    );
  }

  Future<void> _showReplenishmentDialog(
    BuildContext context, {
    required String retailerId,
    required String retailerName,
  }) {
    const _ReplenishmentData errorData = _ReplenishmentData(
      source: _ReplenishmentSource.error,
      rows: <ReplenishmentComparisonRow>[],
      productNames: <String, String>{},
    );
    final Future<_ReplenishmentData> future = retailerId.isEmpty
        ? Future<_ReplenishmentData>.value(errorData)
        : _loadReplenishment(retailerId).catchError((Object _) => errorData);
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Replenishment — $retailerName'),
        content: SizedBox(
          width: 420,
          child: FutureBuilder<_ReplenishmentData>(
            future: future,
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<_ReplenishmentData> snapshot,
                ) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 120),
                      child: SlowLoading(),
                    );
                  }
                  final _ReplenishmentData? data = snapshot.data;
                  if (data == null ||
                      data.source == _ReplenishmentSource.error) {
                    return const Text(
                      'Could not load replenishment suggestions. Check your connection and try again.',
                    );
                  }
                  return SingleChildScrollView(
                    child: _replenishmentContent(data),
                  );
                },
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _replenishmentContent(_ReplenishmentData data) {
    final String sourceLabel = data.source == _ReplenishmentSource.ai
        ? 'AI visit brief'
        : 'Stored weekly forecast readiness';
    if (data.rows.isEmpty && data.readinessRows.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _memorySourceTag(sourceLabel),
          if (data.hasAiData) ...<Widget>[
            const SizedBox(height: 8),
            AiFreshnessChip(
              hasData: true,
              timestamps: <DateTime?>[data.generatedAt],
              hasMissingTimestamp: data.hasMissingTimestamp,
            ),
          ],
          const SizedBox(height: 10),
          Text(
            data.message ??
                'No order suggestion has been published for this shop.',
            style: TextStyle(fontSize: 13),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _memorySourceTag(sourceLabel),
        if (data.hasAiData) ...<Widget>[
          const SizedBox(height: 8),
          AiFreshnessChip(
            hasData: true,
            timestamps: <DateTime?>[data.generatedAt],
            hasMissingTimestamp: data.hasMissingTimestamp,
          ),
        ],
        const SizedBox(height: 10),
        if (data.rows.isEmpty && data.message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              data.message!,
              style: TextStyle(fontSize: 12.5, color: context.dso.muted),
            ),
          ),
        for (final ReplenishmentComparisonRow row in data.rows)
          _replenishmentRow(row, data.productNames[row.productId]),
        if (data.readinessRows.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          const Text(
            'Forecast readiness',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
          ),
          const SizedBox(height: 7),
          for (final Map<String, dynamic> row in data.readinessRows)
            _replenishmentReadinessRow(row, data.productNames),
        ],
      ],
    );
  }

  Widget _replenishmentReadinessRow(
    Map<String, dynamic> row,
    Map<String, String> productNames,
  ) {
    final String productId = _safeText(row['productId'], fallback: '');
    final String storedName = _safeText(row['productName'], fallback: '');
    final String label = storedName.isNotEmpty
        ? storedName
        : productNames[productId] ?? productId;
    final String status = _safeText(
      row['suggestionStatus'],
      fallback: 'forecast_unavailable',
    ).replaceAll('_', ' ');
    final Map<String, dynamic> forecast = row['forecast'] is Map
        ? Map<String, dynamic>.from(row['forecast'] as Map)
        : const <String, dynamic>{};
    final List<String> details = <String>[
      if (_safeText(forecast['periodStart'], fallback: '').isNotEmpty)
        'week ${_safeText(forecast['periodStart'], fallback: '')}',
      if (_safeText(forecast['dataCutoff'], fallback: '').isNotEmpty)
        'data through ${_safeText(forecast['dataCutoff'], fallback: '')}',
      if (_safeText(row['packingSize'], fallback: '').isNotEmpty)
        'pack ${_safeText(row['packingSize'], fallback: '')}',
      if (_safeText(row['unitOfMeasure'], fallback: '').isNotEmpty)
        _safeText(row['unitOfMeasure'], fallback: ''),
    ];
    final String rationale = _safeText(row['rationale'], fallback: '');
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
            status,
            style: TextStyle(fontSize: 12, color: context.dso.warningText),
          ),
          if (details.isNotEmpty)
            Text(
              details.join(' · '),
              style: TextStyle(fontSize: 11.5, color: context.dso.muted),
            ),
          if (rationale.isNotEmpty)
            Text(
              rationale,
              style: TextStyle(fontSize: 11.5, color: context.dso.muted),
            ),
        ],
      ),
    );
  }

  Widget _replenishmentRow(
    ReplenishmentComparisonRow row,
    String? productName,
  ) {
    final String label = (productName == null || productName.isEmpty)
        ? row.productId
        : productName;
    final String lastOrdered = row.lastOrderedQty == null
        ? '—'
        : '${row.lastOrderedQty}';
    final String delta = row.delta == null
        ? ''
        : row.delta! > 0
        ? ' (+${row.delta})'
        : row.delta! < 0
        ? ' (${row.delta})'
        : ' (even)';
    return Builder(
      builder: (BuildContext context) {
        final ColorScheme scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              Text(
                'Suggested ${row.suggestedQty} · last order $lastOrdered$delta '
                '· ${row.confidenceLabel} confidence',
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (row.rationale.isNotEmpty)
                Text(
                  row.rationale,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  String _issueLabel(String issueKey, Map<String, String> productNames) {
    final List<String> parts = issueKey
        .split(':')
        .where((String part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return 'Issue';
    final String issue = reasonCodeLabel(parts.first);
    if (parts.length == 1) return issue;
    return '$issue · ${productNames[parts.last] ?? parts.last}';
  }

  Widget _aiMemoryContent(
    Map<String, dynamic> snapshot,
    Map<String, String> productNames,
  ) {
    final String status = _safeText(snapshot['status'], fallback: 'unknown');
    final int outcomeCount = (snapshot['outcomeCount'] as num?)?.toInt() ?? 0;
    final String confidence = _safeText(
      snapshot['confidenceLabel'],
      fallback: 'low',
    );
    final List<String> reasons = _scoredNames(
      snapshot['commonReasonCodes'],
      key: 'reasonCode',
    ).map(reasonCodeLabel).toList(growable: false);
    final List<String> replacements = _scoredNames(
      snapshot['replacementProducts'],
      key: 'productId',
    ).map((String id) => productNames[id] ?? id).toList(growable: false);
    final List<String> issues = <String>[];
    if (snapshot['lastConfirmedIssues'] is List) {
      for (final Object? row in (snapshot['lastConfirmedIssues'] as List).take(
        3,
      )) {
        if (row is! Map) continue;
        final String reason = _safeText(row['reasonCode'], fallback: '');
        final String key = _safeText(row['issueKey'], fallback: '');
        if (key.isEmpty && reason.isEmpty) continue;
        final DateTime? at = _toDate(row['submittedAt']);
        issues.add(
          '${_issueLabel(key, productNames)} — ${reasonCodeLabel(reason)}'
          '${at == null ? '' : ' (${_formatDate(at)})'}',
        );
      }
    }
    final DateTime? lastOutcomeAt = _toDate(snapshot['lastOutcomeAt']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _memorySourceTag('AI memory snapshot (from the last AI update)'),
        const SizedBox(height: 8),
        AiFreshnessChip(
          hasData: true,
          timestamps: <DateTime?>[aiDataTimestamp(snapshot)],
          hasMissingTimestamp: aiDataTimestamp(snapshot) == null,
        ),
        const SizedBox(height: 10),
        _memoryLine('Status', '$status • $confidence confidence'),
        _memoryLine(
          'Based on',
          '$outcomeCount outcome(s)'
              '${lastOutcomeAt == null ? '' : ' • most recent ${_formatDate(lastOutcomeAt)}'}',
        ),
        if (reasons.isNotEmpty)
          _memoryLine('Common reasons', reasons.join(', ')),
        if (replacements.isNotEmpty)
          _memoryLine('Common replacements', replacements.join(', ')),
        if (issues.isNotEmpty)
          _memoryLine('Last confirmed issues', issues.join('\n')),
        if (outcomeCount == 0 && reasons.isEmpty)
          Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'No memory signals for this retailer yet.',
              style: TextStyle(fontSize: 12.5, color: context.dso.muted),
            ),
          ),
      ],
    );
  }

  Widget _liveMemoryContent(RetailerMemory memory) {
    if (memory.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _memorySourceTag('Derived live from recent conversation outcomes'),
          const SizedBox(height: 10),
          const Text(
            'No recorded outcomes for this retailer yet. Memory builds up as '
            'salesmen record visit outcomes.',
            style: TextStyle(fontSize: 13),
          ),
        ],
      );
    }
    final List<String> reasons = memory.topReasons
        .map(
          (ReasonStat stat) =>
              '${reasonCodeLabel(stat.reasonCode)} ×${stat.count}',
        )
        .toList(growable: false);
    final List<String> issues = memory.lastIssues
        .map(
          (IssueMemory issue) =>
              '${issue.productName.isEmpty ? issue.issueKey : issue.productName}'
              ' — ${reasonCodeLabel(issue.reasonCode)}'
              '${issue.needsFollowUp ? ' (follow-up pending)' : ''}'
              '${issue.at == null ? '' : ' (${_formatDate(issue.at!)})'}',
        )
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _memorySourceTag('Derived live from recent conversation outcomes'),
        const SizedBox(height: 10),
        _memoryLine(
          'Based on',
          '${memory.outcomeCount} outcome(s)'
              '${memory.mostRecentAt == null ? '' : ' • most recent ${_formatDate(memory.mostRecentAt!)}'}'
              ' • ${memory.confidenceLabel} confidence',
        ),
        if (reasons.isNotEmpty)
          _memoryLine('Common reasons', reasons.join(', ')),
        if (memory.isPriceSensitive)
          _memoryLine(
            'Price sensitivity',
            '${(memory.priceSensitivityShare * 100).round()}% of recent outcomes are price-related',
          ),
        if (memory.hasSeasonalitySignal)
          _memoryLine(
            'Seasonality',
            'Seasonal-change outcomes recorded'
                '${memory.lastSeasonalAt == null ? '' : ' (last ${_formatDate(memory.lastSeasonalAt!)})'}',
          ),
        if (memory.commonReplacements.isNotEmpty)
          _memoryLine(
            'Common replacements',
            memory.commonReplacements
                .map(
                  (ReplacementStat stat) => '${stat.productId} ×${stat.count}',
                )
                .join(', '),
          ),
        if (issues.isNotEmpty) _memoryLine('Last issues', issues.join('\n')),
      ],
    );
  }

  Widget _memorySourceTag(String label) {
    return Builder(
      builder: (BuildContext context) {
        final ColorScheme scheme = Theme.of(context).colorScheme;
        final bool dark = scheme.brightness == Brightness.dark;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: dark ? scheme.surfaceContainerHighest : context.dso.infoSoft,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(fontSize: 11.5, color: context.dso.infoText),
          ),
        );
      },
    );
  }

  Widget _memoryLine(String label, String value) {
    return Builder(
      builder: (BuildContext context) {
        final ColorScheme scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              Text(value, style: const TextStyle(fontSize: 13)),
            ],
          ),
        );
      },
    );
  }

  List<String> _scoredNames(Object? value, {required String key}) {
    if (value is! List) return const <String>[];
    final List<String> names = <String>[];
    for (final Object? row in value.take(3)) {
      final String name = row is Map
          ? _safeText(row[key], fallback: '')
          : _safeText(row, fallback: '');
      if (name.isNotEmpty) names.add(name);
    }
    return names;
  }

  DateTime? _toDate(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return DateTime.tryParse(_safeText(value, fallback: ''));
  }

  String _formatDate(DateTime value) =>
      '${value.day}/${value.month}/${value.year}';

  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = false,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        CmsFormLabel(label: label),
        TextFormField(
          controller: controller,
          maxLines: maxLines,
          validator: (String? value) {
            if (!required) return null;
            if (value == null || value.trim().isEmpty) return 'Required';
            return null;
          },
        ),
      ],
    );
  }
}

enum _MemorySource { ai, live, error }

class _RetailerMemoryData {
  const _RetailerMemoryData({
    required this.source,
    this.snapshot,
    this.live,
    this.productNames = const <String, String>{},
  });

  final _MemorySource source;
  final Map<String, dynamic>? snapshot;
  final Map<String, String> productNames;
  final RetailerMemory? live;
}

enum _ReplenishmentSource { ai, live, error }

class _ReplenishmentData {
  const _ReplenishmentData({
    required this.source,
    required this.rows,
    required this.productNames,
    this.readinessRows = const <Map<String, dynamic>>[],
    this.generatedAt,
    this.hasAiData = false,
    this.hasMissingTimestamp = false,
    this.message,
  });

  final _ReplenishmentSource source;
  final List<ReplenishmentComparisonRow> rows;
  final Map<String, String> productNames;
  final List<Map<String, dynamic>> readinessRows;
  final DateTime? generatedAt;
  final bool hasAiData;
  final bool hasMissingTimestamp;
  final String? message;
}

Map<String, String> _weeklyForecastReadiness(
  Map<String, dynamic> forecast, {
  required DateTime today,
}) {
  final String storedStatus = _readinessText(forecast['status']).toLowerCase();
  if (storedStatus == 'stale') {
    return <String, String>{
      'status': 'stale',
      'message': 'Weekly forecast is out of date.',
    };
  }
  if (storedStatus == 'insufficient_history') {
    if (_readinessText(forecast['demandClass']) == 'no_demand') {
      return <String, String>{
        'status': 'no_demand',
        'message':
            'No demand in the completed weekly history; no quantity is suggested.',
      };
    }
    return <String, String>{
      'status': 'insufficient_history',
      'message':
          'Insufficient usable weekly history; no quantity is suggested.',
    };
  }
  if (storedStatus == 'no_demand') {
    return <String, String>{
      'status': 'no_demand',
      'message': 'The weekly forecast is zero; no quantity is suggested.',
    };
  }

  final DateTime currentDate = DateTime.utc(today.year, today.month, today.day);
  final DateTime periodStart = DateTime.utc(
    currentDate.year,
    currentDate.month,
    currentDate.day - (currentDate.weekday - DateTime.monday),
  );
  final DateTime dataCutoff = periodStart.subtract(const Duration(days: 1));
  final DateTime? sourcePeriod = DateTime.tryParse(
    _readinessText(forecast['periodStart']),
  );
  final DateTime? sourceCutoff = DateTime.tryParse(
    _readinessText(forecast['dataCutoff']),
  );
  if (sourcePeriod == null || sourceCutoff == null) {
    return <String, String>{
      'status': 'forecast_unavailable',
      'message': 'Forecast period or data cutoff is unavailable.',
    };
  }
  final DateTime sourcePeriodDate = DateTime.utc(
    sourcePeriod.year,
    sourcePeriod.month,
    sourcePeriod.day,
  );
  final DateTime sourceCutoffDate = DateTime.utc(
    sourceCutoff.year,
    sourceCutoff.month,
    sourceCutoff.day,
  );
  if (sourcePeriodDate.isBefore(periodStart) ||
      sourceCutoffDate.isBefore(dataCutoff)) {
    return <String, String>{
      'status': 'stale',
      'message': 'Forecast data is out of date.',
    };
  }
  if (sourcePeriodDate.isAfter(periodStart) ||
      sourceCutoffDate.isAfter(dataCutoff)) {
    return <String, String>{
      'status': 'forecast_unavailable',
      'message': 'Forecast provenance is inconsistent with the current week.',
    };
  }

  final Object? rawPoint = forecast['point'];
  final double? point = rawPoint is num ? rawPoint.toDouble() : null;
  if (storedStatus == 'ok' && point == 0) {
    return <String, String>{
      'status': 'no_demand',
      'message':
          'The usable weekly forecast is zero; no quantity is suggested.',
    };
  }
  if (storedStatus != 'ok' ||
      forecast['pointSemantics'] !=
          'unconditional_expected_demand_per_period' ||
      point == null ||
      !point.isFinite ||
      point <= 0 ||
      _readinessText(forecast['modelVersion']).isEmpty) {
    return <String, String>{
      'status': 'forecast_unavailable',
      'message': 'Current weekly forecast provenance is incomplete.',
    };
  }
  return <String, String>{
    'status': 'usable',
    'message': 'Current weekly forecast is usable.',
  };
}

String _readinessText(Object? value) => value?.toString().trim() ?? '';

class _CoverageLifecyclePanel extends StatefulWidget {
  const _CoverageLifecyclePanel({
    required this.currentUser,
    required this.repository,
    required this.isDemoRetailer,
    required this.onLastVisitsLoaded,
  });

  final UserProfile currentUser;
  final CmsRepository repository;

  final bool Function(Map<String, dynamic>) isDemoRetailer;
  final ValueChanged<Map<String, DateTime>> onLastVisitsLoaded;

  @override
  State<_CoverageLifecyclePanel> createState() =>
      _CoverageLifecyclePanelState();
}

class _CoverageLifecyclePanelState extends State<_CoverageLifecyclePanel> {
  final RetailerLifecycleService _service = RetailerLifecycleService();

  RetailerLifecycleInputs _inputs = RetailerLifecycleInputs.empty;
  bool _loading = true;
  bool _error = false;
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final int seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final RetailerLifecycleInputs inputs = await _service.loadInputs(
        widget.currentUser,
      );
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _inputs = inputs;
        _loading = false;
        _error = inputs.allSourcesFailed;
      });
      widget.onLastVisitsLoaded(inputs.lastVisitByRetailer);
    } catch (_) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  static const Map<LifecycleStage, String> _stageLabels =
      <LifecycleStage, String>{
        LifecycleStage.newcomer: 'New',
        LifecycleStage.active: 'Active',
        LifecycleStage.atRisk: 'At risk',
        LifecycleStage.dormant: 'Dormant',
        LifecycleStage.churned: 'Churned',
        LifecycleStage.neverOrdered: 'Never ordered',
        LifecycleStage.orderHistoryUnknown: 'Order history incomplete',
      };

  static const Map<LifecycleStage, Color> _stageColors =
      <LifecycleStage, Color>{
        LifecycleStage.newcomer: Color(0xFF2563EB),
        LifecycleStage.active: Color(0xFF12B76A),
        LifecycleStage.atRisk: Color(0xFFB54708),
        LifecycleStage.dormant: Color(0xFFD92D20),
        LifecycleStage.churned: Color(0xFFB42318),
        LifecycleStage.neverOrdered: Color(0xFF667085),
        LifecycleStage.orderHistoryUnknown: Color(0xFF98A2B3),
      };

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_loading) {
      body = const SlowLoading();
    } else if (_error) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Coverage signals could not be read. Check your connection and '
              'access, then retry.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: context.dso.muted),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _load,
              icon: const Icon(ScootIcons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    } else {
      body = _coverageBody();
    }
    return CmsPanel(title: 'Coverage & Lifecycle', child: body);
  }

  Widget _coverageBody() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: widget.repository.watchCollection(
        'retailers',
        orderBy: 'retailerName',
      ),
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
          ) {
            if (!snapshot.hasData) {
              return const SlowLoading();
            }
            if (!collectionRowsComplete(snapshot.data) ||
                _inputs.failedSources.isNotEmpty ||
                _inputs.incompleteSources.isNotEmpty) {
              return const Center(
                child: Text(
                  'Incomplete — lifecycle and visit counts '
                  'are unavailable until all bounded inputs can be verified.',
                ),
              );
            }
            final List<LifecycleRetailer> retailers =
                lifecycleRetailersFromRows(
                  snapshot.data!
                      .where(
                        (Map<String, dynamic> row) =>
                            !widget.isDemoRetailer(row),
                      )
                      .toList(growable: false),
                );
            if (retailers.isEmpty) {
              return Center(
                child: Text(
                  'No retailers to classify yet.',
                  style: TextStyle(fontSize: 12.5, color: context.dso.muted),
                ),
              );
            }
            final List<RetailerLifecycle> classified = deriveRetailerLifecycles(
              retailers: retailers,
              orderStatsByRetailer: _inputs.orderStatsByRetailer,
              riskInsightCountByRetailer: _inputs.riskInsightCountByRetailer,
              memoryConfidenceByRetailer: _inputs.memoryConfidenceByRetailer,
              lastVisitByRetailer: _inputs.lastVisitByRetailer,
              orderHistoryComplete: _inputs.orderHistoryComplete,
              now: DateTime.now(),
            );
            final Map<LifecycleStage, int> counts = <LifecycleStage, int>{};
            int neverAssigned = 0;
            int longUncovered = 0;
            for (final RetailerLifecycle item in classified) {
              counts.update(item.stage, (int v) => v + 1, ifAbsent: () => 1);
              if (item.neverAssigned) neverAssigned++;
              if (item.longUncovered) longUncovered++;
            }
            final List<RetailerLifecycle> attention = classified
                .where(
                  (RetailerLifecycle item) =>
                      item.stage != LifecycleStage.active ||
                      item.neverAssigned ||
                      item.longUncovered,
                )
                .toList(growable: false);
            return ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                AiFreshnessChip(
                  hasData: _inputs.hasAiData,
                  timestamps: _inputs.aiTimestamps,
                  hasMissingTimestamp: _inputs.hasMissingAiTimestamp,
                ),
                const SizedBox(height: 10),
                if (_inputs.failedSources.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      'Some signals could not be read '
                      '(${_inputs.failedSources.join(', ')}) — stages lean on '
                      'the remaining signals only.',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.dso.warningText,
                      ),
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final LifecycleStage stage in LifecycleStage.values)
                      if ((counts[stage] ?? 0) > 0)
                        _countChip(
                          _stageLabels[stage] ?? stage.name,
                          counts[stage]!,
                          _stageColors[stage] ?? context.dso.muted,
                        ),
                    if (neverAssigned > 0)
                      _countChip(
                        'Never assigned',
                        neverAssigned,
                        context.dso.dangerText,
                      ),
                    if (longUncovered > 0)
                      _countChip(
                        'Long-uncovered',
                        longUncovered,
                        context.dso.warningText,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (attention.isEmpty)
                  Text(
                    'Every classified retailer is active, assigned and '
                    'recently covered.',
                    style: TextStyle(fontSize: 12.5, color: context.dso.muted),
                  )
                else ...<Widget>[
                  Text(
                    '${attention.length} retailer(s) need attention',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final RetailerLifecycle item in attention)
                    _attentionRow(item),
                ],
              ],
            );
          },
    );
  }

  Widget _countChip(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        '$label: $count',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _attentionRow(RetailerLifecycle item) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = _stageColors[item.stage] ?? context.dso.muted;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              _stageLabels[item.stage] ?? item.stage.name,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TipText(
                  item.retailerName,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.reason,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
