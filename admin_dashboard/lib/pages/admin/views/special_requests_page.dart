import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../repositories/catalogue_product_repository.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/snapshot_load_state.dart';
import '../../../utils/user_facing_error.dart';
import '../widgets/order_details_dialog.dart';
import 'special_requests_view.dart';

class SpecialRequestsPage extends StatefulWidget {
  const SpecialRequestsPage({super.key, required this.currentUser});

  final UserProfile currentUser;

  @override
  State<SpecialRequestsPage> createState() => _SpecialRequestsPageState();
}

class _SpecialRequestsPageState extends State<SpecialRequestsPage> {
  final CmsRepository _repository = CmsRepository();
  final CatalogueProductRepository _catalogueRepository =
      CatalogueProductRepository();
  final TextEditingController _retailerController = TextEditingController();
  final TextEditingController _itemController = TextEditingController();
  final TextEditingController _reasonController = TextEditingController();
  late Stream<List<Map<String, dynamic>>> _requestsStream = _openRequests();

  Stream<List<Map<String, dynamic>>> _openRequests() =>
      _repository.watchSpecialRequests(currentUser: widget.currentUser);

  late final Stream<List<Map<String, dynamic>>> _usersStream = _repository
      .watchCollection('users', orderBy: 'name');
  late final Stream<List<Map<String, dynamic>>> _branchesStream = _repository
      .watchCollection('branches', orderBy: 'branchName');
  String _salesmanCode = '';
  String _branchId = '';
  bool _creating = false;
  final Set<String> _busyIds = <String>{};

  @override
  void initState() {
    super.initState();
    _branchId = widget.currentUser.branchId.trim();
    if (widget.currentUser.assignedSalesmanCodes.length == 1) {
      _salesmanCode = widget.currentUser.assignedSalesmanCodes.single;
    }
  }

  @override
  void dispose() {
    _retailerController.dispose();
    _itemController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  Future<bool> _createRequest() async {
    if (widget.currentUser.isBranchManager || _creating) return false;
    final String retailer = _retailerController.text.trim();
    final String item = _itemController.text.trim();
    final String salesmanCode = _salesmanCode.trim();
    final String branchId = _branchId.trim();
    if (retailer.isEmpty ||
        item.isEmpty ||
        salesmanCode.isEmpty ||
        branchId.isEmpty) {
      _toast('Retailer, item, salesperson and branch are required.');
      return false;
    }
    final User? authUser = FirebaseAuth.instance.currentUser;
    if (authUser == null || authUser.uid.trim().isEmpty) {
      _toast(
        'Your session has expired. Sign in again before creating a request.',
      );
      return false;
    }
    setState(() => _creating = true);
    try {
      await _repository.addDocument(
        collectionName: 'special_requests',
        data: <String, dynamic>{
          'retailerName': retailer,
          'requestedItem': item,
          'reason': _reasonController.text.trim(),
          'salesmanCode': salesmanCode,
          'branchId': branchId,
          'createdByUid': authUser.uid,
          'createdByRole': widget.currentUser.role,
          'status': 'pending_admin',
          'approvalStep': 'Admin',
          'lastActorUid': authUser.uid,
          'lastActorRole': widget.currentUser.role,
          'lastActionAt': FieldValue.serverTimestamp(),
        },
      );
      _retailerController.clear();
      _itemController.clear();
      _reasonController.clear();
      if (mounted) {
        setState(() {
          if (widget.currentUser.assignedSalesmanCodes.length != 1) {
            _salesmanCode = '';
          }
          if (widget.currentUser.branchId.isEmpty) _branchId = '';
        });
      }
      _toast('Request created.');
      return true;
    } catch (error, stackTrace) {
      AppLogger.error(
        'special_request_create_failed',
        error: error,
        stackTrace: stackTrace,
      );
      _toast(userFacingError(error, action: 'create the request'));
      return false;
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _move(
    String docId,
    String status,
    String step, {
    String? confirmLabel,
  }) async {
    if (docId.isEmpty) {
      _toast('This request is missing an ID and cannot be updated.');
      return;
    }
    if (!_busyIds.add(docId)) return;
    setState(() {});
    try {
      await _repository.upsertDocument(
        collectionName: 'special_requests',
        docId: docId,
        data: <String, dynamic>{
          'status': status,
          'approvalStep': step,
          'lastActorUid': FirebaseAuth.instance.currentUser?.uid ?? '',
          'lastActorRole': widget.currentUser.role,
          'lastActionAt': FieldValue.serverTimestamp(),
        },
      );
      _toast(confirmLabel ?? 'Updated.');
    } catch (error, stackTrace) {
      AppLogger.error(
        'special_request_update_failed',
        error: error,
        stackTrace: stackTrace,
        fields: <String, Object?>{'docId': docId, 'targetStatus': status},
      );
      _toast(userFacingError(error, action: 'update the request'));
    } finally {
      _busyIds.remove(docId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _approveCatalogue(Map<String, dynamic> row) async {
    final docId = _text(row['docId']);
    if (!widget.currentUser.isAdmin || !_busyIds.add(docId)) return;
    setState(() {});
    try {
      String? existingProductId;
      if (_text(row['selectedProductId']).isEmpty &&
          _text(row['catalogueProductId']).isEmpty) {
        final products = await FirebaseFirestore.instance
            .collection('products')
            .get();
        final name = _text(
          row['requestedItem'],
        ).toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        final collisions = products.docs
            .where(
              (doc) =>
                  <String>[
                    _text(doc.data()['itemName']),
                    _text(doc.data()['productName']),
                  ].any(
                    (value) =>
                        value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ') ==
                        name,
                  ),
            )
            .toList();
        if (!mounted) return;
        if (collisions.isNotEmpty) {
          existingProductId = await showDialog<String>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('Choose the existing product'),
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'This name already exists. Select the correct product; its name and price will be preserved.',
                  ),
                ),
                for (final doc in collisions)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, doc.id),
                    child: Text(
                      '${_text(doc.data()['itemName'] ?? doc.data()['productName'])} [${doc.id}]',
                    ),
                  ),
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          );
          if (existingProductId == null) return;
        }
      }
      final SpecialRequestApproval approval = await _catalogueRepository
          .approveSpecialRequest(
            requestId: docId,
            actorUid: FirebaseAuth.instance.currentUser?.uid ?? '',
            actorRole: widget.currentUser.role,
            existingProductId: existingProductId,
          );
      final String? hiddenReason = approval.hiddenReason;
      _toast(
        hiddenReason == null
            ? 'Request approved. Item added to the retailer catalogue.'
            : 'Approved, but hidden: $hiddenReason',
      );
    } catch (error, stackTrace) {
      AppLogger.error(
        'special_request_catalogue_failed',
        error: error,
        stackTrace: stackTrace,
      );
      _toast(
        error is StateError
            ? error.message.toString()
            : userFacingError(
                error,
                action: 'add the requested item to the catalogue',
              ),
      );
    } finally {
      _busyIds.remove(docId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _migrateLegacy(Map<String, dynamic> row) async {
    if (!widget.currentUser.isAdmin) return;
    final String docId = _text(row['docId']);
    if (docId.isEmpty) return;
    final TextEditingController salesmanController = TextEditingController(
      text: _text(row['salesmanCode']),
    );
    final TextEditingController branchController = TextEditingController(
      text: _text(row['branchId']),
    );
    final Map<String, String>? values = await showDialog<Map<String, String>>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Upgrade legacy request'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                'This record predates scoped approvals. Review the text, then assign its salesman and branch. It will return to the Supervisor step.',
              ),
              const SizedBox(height: 14),
              TextField(
                controller: salesmanController,
                maxLength: 100,
                decoration: const InputDecoration(labelText: 'Salesman code'),
              ),
              TextField(
                controller: branchController,
                maxLength: 100,
                decoration: const InputDecoration(labelText: 'Branch ID'),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, <String, String>{
              'salesmanCode': salesmanController.text.trim(),
              'branchId': branchController.text.trim(),
            }),
            child: const Text('Upgrade'),
          ),
        ],
      ),
    );
    salesmanController.dispose();
    branchController.dispose();
    if (values == null) return;
    final String salesmanCode = values['salesmanCode'] ?? '';
    final String branchId = values['branchId'] ?? '';
    if (salesmanCode.isEmpty || branchId.isEmpty) {
      _toast('Salesman code and branch ID are required.');
      return;
    }
    final User? authUser = FirebaseAuth.instance.currentUser;
    if (authUser == null || authUser.uid.trim().isEmpty) {
      _toast('Your session has expired. Sign in again before upgrading.');
      return;
    }
    final String actorRole = widget.currentUser.role;
    final String existingCreatorUid = _text(row['createdByUid']);
    final String existingCreatorRole = _text(row['createdByRole']);
    final bool existingCreatorPairIsValid =
        existingCreatorUid.isNotEmpty &&
        _validRoles.contains(existingCreatorRole);
    final String creatorUid = existingCreatorPairIsValid
        ? existingCreatorUid
        : authUser.uid;
    final String creatorRole = existingCreatorPairIsValid
        ? existingCreatorRole
        : actorRole;
    try {
      await _repository.upsertDocument(
        collectionName: 'special_requests',
        docId: docId,
        merge: false,
        data: <String, dynamic>{
          'retailerName': _text(row['retailerName']),
          'requestedItem': _text(row['requestedItem']),
          'reason': _text(row['reason']),
          'salesmanCode': salesmanCode,
          'branchId': branchId,
          'createdByUid': creatorUid,
          'createdByRole': creatorRole,
          'createdAt': row['createdAt'] is Timestamp
              ? row['createdAt']
              : FieldValue.serverTimestamp(),
          'status': 'pending_supervisor',
          'approvalStep': 'Supervisor',
          'lastActorUid': authUser.uid,
          'lastActorRole': actorRole,
          'lastActionAt': FieldValue.serverTimestamp(),
        },
      );
      _toast('Legacy request upgraded and sent to Supervisor.');
    } catch (error, stackTrace) {
      AppLogger.error(
        'special_request_legacy_upgrade_failed',
        error: error,
        stackTrace: stackTrace,
        fields: <String, Object?>{'docId': docId},
      );
      _toast(userFacingError(error, action: 'upgrade the legacy request'));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _requestsStream,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
          ) {
            final SnapshotLoadState loadState = snapshotLoadState(
              isWaiting: snapshot.connectionState == ConnectionState.waiting,
              hasData: snapshot.hasData,
              hasError: snapshot.hasError,
            );
            return SpecialRequestsView(
              phase: switch (loadState) {
                SnapshotLoadState.loading => ScootLoadPhase.loading,
                SnapshotLoadState.error => ScootLoadPhase.error,
                _ => ScootLoadPhase.ready,
              },
              onRetry: () => setState(() {
                _requestsStream = _openRequests();
              }),
              rows: snapshot.data ?? <Map<String, dynamic>>[],
              isBranchManager: widget.currentUser.isBranchManager,
              isAdmin: widget.currentUser.isAdmin,
              canDecide: (Map<String, dynamic> row) =>
                  _canDecide(row, _text(row['status']).toLowerCase()),
              isLegacy: _isLegacyRow,
              busyIds: _busyIds,
              onNewRequest: _openNewRequest,
              onApprove: _approve,
              onReject: _confirmReject,
              onAddToCatalogue: _approveCatalogue,
              onUpgradeLegacy: _migrateLegacy,
              onOpenOrder: (String orderId) => OrderDetailsDialog.show(
                context,
                orderDocumentId: orderId,
                repository: _repository,
                currentUser: widget.currentUser,
              ),
            );
          },
    );
  }

  void _approve(Map<String, dynamic> row) {
    final String docId = _text(row['docId']);
    final bool other = _text(row['requestType']) == 'non_catalogue_item';
    if (widget.currentUser.isAdmin && other) {
      _approveCatalogue(row);
      return;
    }
    _move(
      docId,
      'approved',
      'Approved',
      confirmLabel: other
          ? 'Approved - awaiting admin to add product.'
          : 'Request approved.',
    );
  }

  Future<void> _confirmReject(Map<String, dynamic> row) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Reject this request?'),
        content: Text(
          'The request for ${_text(row['requestedItem'])} will be rejected. This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey<String>('sr-reject-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _move(
      _text(row['docId']),
      'rejected',
      'Rejected',
      confirmLabel: 'Request rejected.',
    );
  }

  Future<void> _openNewRequest() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialog) => AlertDialog(
          title: const Text('New special request'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    controller: _retailerController,
                    decoration: const InputDecoration(labelText: 'Retailer'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _itemController,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: 'Requested item',
                    ),
                  ),
                  const SizedBox(height: 12),
                  _salesmanField(setDialog),
                  const SizedBox(height: 12),
                  _branchField(setDialog),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _reasonController,
                    maxLines: 3,
                    maxLength: 1000,
                    decoration: const InputDecoration(
                      labelText: 'Reason / remark',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey<String>('sr-create'),
              onPressed: _creating
                  ? null
                  : () async {
                      setDialog(() {});
                      final bool created = await _createRequest();
                      if (created && dialogContext.mounted) {
                        Navigator.pop(dialogContext);
                      } else if (dialogContext.mounted) {
                        setDialog(() {});
                      }
                    },
              child: Text(_creating ? 'Creating' : 'Create'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _salesmanField(StateSetter setDialog) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _usersStream,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
          ) {
            final List<SpecialRequestChoice> options = salesmanChoices(
              snapshot.data ?? <Map<String, dynamic>>[],
              restrictToCodes: widget.currentUser.isAdmin
                  ? null
                  : widget.currentUser.assignedSalesmanCodes,
            );
            return _choiceDropdown(
              label: 'Salesperson',
              emptyHint: 'No salespeople found',
              options: options,
              value: _salesmanCode,
              onChanged: (String value) {
                _salesmanCode = value;
                setDialog(() {});
              },
            );
          },
    );
  }

  Widget _branchField(StateSetter setDialog) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _branchesStream,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
          ) {
            final String ownBranch = widget.currentUser.branchId.trim();
            final List<SpecialRequestChoice> options = branchChoices(
              snapshot.data ?? <Map<String, dynamic>>[],
              lockedBranchId: ownBranch,
            );
            return _choiceDropdown(
              label: 'Branch',
              emptyHint: 'No branches yet - create one first',
              options: options,
              value: _branchId,
              onChanged: ownBranch.isNotEmpty
                  ? null
                  : (String value) {
                      _branchId = value;
                      setDialog(() {});
                    },
            );
          },
    );
  }

  Widget _choiceDropdown({
    required String label,
    required String emptyHint,
    required List<SpecialRequestChoice> options,
    required String value,
    required ValueChanged<String>? onChanged,
  }) {
    final bool hasValue = options.any(
      (SpecialRequestChoice option) => option.value == value,
    );
    return DropdownButtonFormField<String>(
      key: ValueKey<String>('$label-$value-${options.length}'),
      initialValue: hasValue ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      hint: Text(options.isEmpty ? emptyHint : 'Select'),
      items: <DropdownMenuItem<String>>[
        for (final SpecialRequestChoice option in options)
          DropdownMenuItem<String>(
            value: option.value,
            child: Text(option.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged == null
          ? null
          : (String? next) => onChanged(next ?? ''),
    );
  }

  bool _isLegacyRow(Map<String, dynamic> row) {
    return !_requiredFields.every(row.containsKey);
  }

  bool _canDecide(Map<String, dynamic> row, String status) {
    if (_isLegacyRow(row)) return false;
    if (status != 'pending_supervisor' &&
        status != 'pending_branch_manager' &&
        status != 'pending_admin') {
      return false;
    }
    final UserProfile user = widget.currentUser;
    if (user.isAdmin) return true;
    return user.isSupervisor &&
        status == 'pending_supervisor' &&
        _text(row['createdByUid']) !=
            (FirebaseAuth.instance.currentUser?.uid ?? '') &&
        user.assignedSalesmanCodes.contains(_text(row['salesmanCode']));
  }

  static String _text(Object? value) {
    if (value == null) return '';
    final String text = value.toString().trim();
    return text.toLowerCase() == 'null' ? '' : text;
  }

  static const Set<String> _requiredFields = <String>{
    'retailerName',
    'requestedItem',
    'reason',
    'salesmanCode',
    'branchId',
    'createdByUid',
    'createdByRole',
    'createdAt',
    'updatedAt',
    'status',
    'approvalStep',
    'lastActorUid',
    'lastActorRole',
    'lastActionAt',
  };

  static const Set<String> _validRoles = <String>{
    'admin',
    'developer',
    'supervisor',
    'branch_manager',
    'salesman',
    'Sales Representative',
    'sales representative',
  };
}

class SpecialRequestChoice {
  const SpecialRequestChoice(this.value, this.label);

  final String value;
  final String label;
}

String _choiceText(Object? value) {
  if (value == null) return '';
  final String text = value.toString().trim();
  return text.toLowerCase() == 'null' ? '' : text;
}

List<SpecialRequestChoice> salesmanChoices(
  Iterable<Map<String, dynamic>> users, {
  Iterable<String>? restrictToCodes,
}) {
  final Set<String>? allowed = restrictToCodes
      ?.map((String code) => code.trim())
      .where((String code) => code.isNotEmpty)
      .toSet();
  final Map<String, SpecialRequestChoice> byCode =
      <String, SpecialRequestChoice>{};
  for (final Map<String, dynamic> user in users) {
    final String role = _choiceText(
      user['role'] ?? user['user_group'] ?? user['roleLabel'],
    ).toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
    final bool isSalesman =
        role.contains('sales') || role.contains('representative');
    if (!isSalesman) continue;
    final String code = _choiceText(
      user['salesmanCode'] ?? user['employeeCode'] ?? user['employee_code'],
    );
    if (code.isEmpty) continue;
    if (allowed != null && !allowed.contains(code)) continue;
    final String name = _choiceText(user['name'] ?? user['displayName']);
    byCode.putIfAbsent(
      code,
      () => SpecialRequestChoice(code, name.isEmpty ? code : '$name ($code)'),
    );
  }
  if (allowed != null) {
    for (final String code in allowed) {
      byCode.putIfAbsent(code, () => SpecialRequestChoice(code, code));
    }
  }
  final List<SpecialRequestChoice> list = byCode.values.toList()
    ..sort(
      (SpecialRequestChoice a, SpecialRequestChoice b) =>
          a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
  return list;
}

List<SpecialRequestChoice> branchChoices(
  Iterable<Map<String, dynamic>> branches, {
  String lockedBranchId = '',
}) {
  final Map<String, SpecialRequestChoice> byId =
      <String, SpecialRequestChoice>{};
  for (final Map<String, dynamic> branch in branches) {
    final String id = _choiceText(branch['docId'] ?? branch['branchId']);
    if (id.isEmpty) continue;
    if (lockedBranchId.isNotEmpty && id != lockedBranchId) continue;
    final String name = _choiceText(branch['branchName']);
    byId.putIfAbsent(
      id,
      () => SpecialRequestChoice(id, name.isEmpty ? id : name),
    );
  }
  if (lockedBranchId.isNotEmpty) {
    byId.putIfAbsent(
      lockedBranchId,
      () => SpecialRequestChoice(lockedBranchId, lockedBranchId),
    );
  }
  final List<SpecialRequestChoice> list = byId.values.toList()
    ..sort(
      (SpecialRequestChoice a, SpecialRequestChoice b) =>
          a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
  return list;
}
