import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../services/external_link_opener.dart';
import '../../../services/retailer_coordinate_proposal_service.dart';
import '../../../utils/csv_export.dart';
import '../../../utils/geo_field_utils.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/retailer_coordinate_edit.dart';
import '../../../utils/retailer_readiness.dart';
import '../../../utils/user_facing_error.dart';
import '../../../widgets/cms_feedback.dart';
import '../../../widgets/retailer_map/coordinate_edit_dialog.dart';
import '../../../widgets/retailer_map/retailer_map_models.dart';
import '../../../widgets/retailer_map/retailer_map_view.dart';
import '../widgets/cms_panel.dart';
import '../../../widgets/slow_loading.dart';

class CoordinateReviewPage extends StatefulWidget {
  const CoordinateReviewPage({super.key, required this.currentUser});

  final UserProfile currentUser;

  @override
  State<CoordinateReviewPage> createState() => _CoordinateReviewPageState();
}

class _CoordinateReviewPageState extends State<CoordinateReviewPage> {
  final CmsRepository _repository = CmsRepository();
  final RetailerCoordinateProposalService _proposalService =
      RetailerCoordinateProposalService();
  final TextEditingController _searchController = TextEditingController();

  List<_CoordinateRow> _rows = <_CoordinateRow>[];
  StreamSubscription<List<Map<String, dynamic>>>? _retailerSubscription;
  late Stream<List<Map<String, dynamic>>> _proposalStream;
  bool _loading = true;
  String _filter = 'issues';
  String _message = '';
  final ValueNotifier<String?> _hoveredId = ValueNotifier<String?>(null);
  final ValueNotifier<String?> _selectedId = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    _proposalStream = _proposalService.watchProposals(widget.currentUser);
    _selectedId.addListener(() => setState(() {}));
    _subscribeRetailers();
  }

  @override
  void didUpdateWidget(CoordinateReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUser.uid != widget.currentUser.uid ||
        oldWidget.currentUser.role != widget.currentUser.role ||
        oldWidget.currentUser.branchId != widget.currentUser.branchId ||
        oldWidget.currentUser.assignedSalesmanCodes.join('|') !=
            widget.currentUser.assignedSalesmanCodes.join('|')) {
      _proposalStream = _proposalService.watchProposals(widget.currentUser);
    }
  }

  @override
  void dispose() {
    _retailerSubscription?.cancel();
    _searchController.dispose();
    _hoveredId.dispose();
    _selectedId.dispose();
    super.dispose();
  }

  void _subscribeRetailers() {
    _retailerSubscription?.cancel();
    setState(() {
      _loading = true;
      _message = '';
    });
    _retailerSubscription = _repository
        .watchCollectionRaw('retailers', limit: 3000)
        .listen(
          _applyRetailerRows,
          onError: (Object error, StackTrace _) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _message = userFacingError(
                error,
                action: 'load retailer coordinates',
              );
            });
          },
        );
  }

  void _applyRetailerRows(List<Map<String, dynamic>> input) {
    final List<Map<String, dynamic>> retailers = input
        .where((Map<String, dynamic> retailer) {
          if (isDemoRetailerRecord(retailer)) return false;
          final String status = (retailer['status'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          return status != 'retired';
        })
        .toList(growable: false);
    final Map<String, int> coordinateCounts = <String, int>{};
    for (final Map<String, dynamic> retailer in retailers) {
      final LatLng? point = readLatLng(retailer);
      if (point == null) continue;
      final String key = _coordinateKey(point.latitude, point.longitude);
      coordinateCounts[key] = (coordinateCounts[key] ?? 0) + 1;
    }
    final List<_CoordinateRow> rows =
        retailers
            .map((Map<String, dynamic> retailer) {
              final LatLng? point = readLatLng(retailer);
              final bool hasFields = hasCoordinateFields(retailer);
              final bool duplicate =
                  point != null &&
                  (coordinateCounts[_coordinateKey(
                            point.latitude,
                            point.longitude,
                          )] ??
                          0) >
                      1;
              return _CoordinateRow(
                data: retailer,
                point: point,
                missing: point == null && !hasFields,
                invalid: point == null && hasFields,
                needsReview: retailerNeedsCoordinateReview(retailer),
                duplicate: duplicate,
              );
            })
            .toList(growable: false)
          ..sort((_CoordinateRow a, _CoordinateRow b) {
            final int issueOrder = b.issueCount.compareTo(a.issueCount);
            if (issueOrder != 0) return issueOrder;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
      _message = '';
    });
  }

  List<_CoordinateRow> get _visibleRows {
    final String query = _searchController.text.trim().toLowerCase();
    return _rows
        .where((_CoordinateRow row) {
          final bool filterMatch = switch (_filter) {
            'missing' => row.missing,
            'invalid' => row.invalid,
            'duplicate' => row.duplicate,
            'valid' => row.point != null && !row.duplicate && !row.needsReview,
            'all' => true,
            _ => row.issueCount > 0,
          };
          if (!filterMatch) return false;
          if (query.isEmpty) return true;
          return row.name.toLowerCase().contains(query) ||
              row.id.toLowerCase().contains(query) ||
              row.address.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  Future<void> _edit(_CoordinateRow row) async {
    final CoordinateEditOutcome? outcome = await showCoordinateEditDialog(
      context,
      retailer: row.data,
      retailerName: row.name,
      address: row.address,
      initialLatitude: row.point?.latitude.toStringAsFixed(6) ?? '',
      initialLongitude: row.point?.longitude.toStringAsFixed(6) ?? '',
      reviewerUid: widget.currentUser.uid ?? '',
    );
    if (outcome == null) return;
    try {
      await _saveIfPointUnchanged(row, outcome.payload);
      if (!mounted) return;
      final String message = outcome.verified
          ? 'Coordinates saved and verified for ${row.name}.'
          : 'Candidate coordinates saved for ${row.name}; still needs review.';
      setState(() => _message = message);
      showCmsToast(context, message);
      _subscribeRetailers();
    } catch (error) {
      _reportFailure(error, 'save the coordinates');
    }
  }

  Future<void> _saveIfPointUnchanged(
    _CoordinateRow row,
    Map<String, dynamic> payload,
  ) {
    return _repository.mergeDocumentIfUnchanged(
      collectionName: 'retailers',
      docId: row.id,
      stillMatches: (Map<String, dynamic>? current) =>
          current != null && readLatLng(current) == row.point,
      data: payload,
      staleMessage:
          'these coordinates were changed by someone else. Review the '
          'latest values and try again.',
    );
  }

  void _reportFailure(Object error, String action) {
    if (!mounted) return;
    final String message = userFacingError(error, action: action);
    setState(() => _message = message);
    showCmsToast(context, message, isError: true);
  }

  Future<void> _markReviewed(_CoordinateRow row) async {
    final LatLng? point = row.point;
    if (point == null) return;
    try {
      await _saveIfPointUnchanged(
        row,
        verifiedCoordinatePayload(
          original: row.data,
          latitudeText: point.latitude.toString(),
          longitudeText: point.longitude.toString(),
          reviewerUid: widget.currentUser.uid ?? '',
          reviewedAt: FieldValue.serverTimestamp(),
        ),
      );
      if (!mounted) return;
      final String message = '${row.name} marked reviewed.';
      setState(() => _message = message);
      showCmsToast(context, message);
      _subscribeRetailers();
    } catch (error) {
      _reportFailure(error, 'mark the retailer as reviewed');
    }
  }

  Future<void> _reviewProposal(
    Map<String, dynamic> proposal, {
    required bool approve,
  }) async {
    final String proposalId = '${proposal['docId'] ?? ''}'.trim();
    final String retailerId = '${proposal['retailerId'] ?? ''}'.trim();
    final _CoordinateRow? retailer = _rows.cast<_CoordinateRow?>().firstWhere(
      (_CoordinateRow? row) => row?.id == retailerId,
      orElse: () => null,
    );
    final double? latitude = (proposal['candidateLatitude'] as num?)
        ?.toDouble();
    final double? longitude = (proposal['candidateLongitude'] as num?)
        ?.toDouble();
    if (proposalId.isEmpty ||
        (approve &&
            (retailer == null || latitude == null || longitude == null))) {
      setState(
        () => _message = 'This pin proposal is missing valid retailer data.',
      );
      return;
    }
    if (approve) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: Text('Verify ${retailer!.name} at this pin?'),
          content: Text(
            '${latitude!.toStringAsFixed(6)}, ${longitude!.toStringAsFixed(6)}\n\n'
            'This replaces the canonical retailer coordinates and marks them verified.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Approve & verify'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    try {
      await _proposalService.review(
        reviewer: widget.currentUser,
        proposalId: proposalId,
        approve: approve,
      );
      if (!mounted) return;
      setState(() {
        _message = approve
            ? 'Candidate pin approved and verified for ${retailer!.name}.'
            : 'Pin proposal rejected; canonical coordinates were unchanged.';
      });
      if (approve) _subscribeRetailers();
    } catch (error) {
      _reportFailure(error, 'review the pin proposal');
    }
  }

  Future<void> _openMap(_CoordinateRow row) async {
    final LatLng? point = row.point;
    final String query = point == null
        ? row.address.trim()
        : '${point.latitude},${point.longitude}';
    if (query.isEmpty) {
      if (mounted) {
        setState(
          () => _message = 'Add an address or coordinates before opening Maps.',
        );
      }
      return;
    }
    final String url =
        'https://www.google.com/maps/search/?api=1&query='
        '${Uri.encodeQueryComponent(query)}';
    final bool opened = await openExternalUrl(url);
    if (!mounted) return;
    setState(() {
      _message = opened
          ? 'Google Maps opened for ${row.name}.'
          : 'The browser blocked Google Maps. Allow pop-ups and try again.';
    });
  }

  Future<void> _copyCsv() async {
    final StringBuffer csv = StringBuffer(
      'retailerId,name,address,latitude,longitude,missing,invalid,duplicate\n',
    );
    for (final _CoordinateRow row in _visibleRows) {
      csv.writeln(
        <String>[
          csvCell(row.id),
          csvCell(row.name),
          csvCell(row.address),
          row.point?.latitude.toString() ?? '',
          row.point?.longitude.toString() ?? '',
          row.missing.toString(),
          row.invalid.toString(),
          row.duplicate.toString(),
        ].join(','),
      );
    }
    await Clipboard.setData(ClipboardData(text: csv.toString()));
    if (!mounted) return;
    setState(() => _message = 'Coordinate review CSV copied to clipboard.');
  }

  @override
  Widget build(BuildContext context) {
    final List<_CoordinateRow> visible = _visibleRows;
    final List<RetailerMapPoint> mapPoints = <RetailerMapPoint>[
      for (final _CoordinateRow row in visible)
        if (row.point != null &&
            (row.needsReview || row.id == _selectedId.value))
          RetailerMapPoint.fromRow(row.data),
    ];
    final int missing = _rows.where((_CoordinateRow row) => row.missing).length;
    final int invalid = _rows.where((_CoordinateRow row) => row.invalid).length;
    final int duplicates = _rows
        .where((_CoordinateRow row) => row.duplicate)
        .length;
    final int needsReview = _rows
        .where((_CoordinateRow row) => row.needsReview)
        .length;
    return CmsPanel(
      title: 'Retailer coordinates',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextButton.icon(
            onPressed: _loading ? null : _copyCsv,
            icon: const Icon(Icons.copy_all_outlined, size: 17),
            label: const Text('Copy CSV'),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _subscribeRetailers,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      child: _loading
          ? const SlowLoading()
          : LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final bool narrow = constraints.maxWidth < 600;
                final Widget filterDropdown = DropdownButton<String>(
                  value: _filter,
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem(
                      value: 'issues',
                      child: Text('All issues'),
                    ),
                    DropdownMenuItem(value: 'missing', child: Text('Missing')),
                    DropdownMenuItem(value: 'invalid', child: Text('Invalid')),
                    DropdownMenuItem(
                      value: 'duplicate',
                      child: Text('Duplicate'),
                    ),
                    DropdownMenuItem(value: 'valid', child: Text('Valid')),
                    DropdownMenuItem(
                      value: 'all',
                      child: Text('All retailers'),
                    ),
                  ],
                  onChanged: (String? value) {
                    if (value != null) setState(() => _filter = value);
                  },
                );
                final Widget searchField = TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search retailer, ID, or address',
                  ),
                );
                return CustomScrollView(
                  slivers: <Widget>[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: <Widget>[
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: <Widget>[
                                _summary(
                                  'Retailers',
                                  _rows.length,
                                  Colors.blue,
                                ),
                                _summary('Missing', missing, Colors.orange),
                                _summary('Invalid', invalid, Colors.red),
                                _summary(
                                  'Needs review',
                                  needsReview,
                                  Colors.amber,
                                ),
                                _summary(
                                  'Duplicate',
                                  duplicates,
                                  Colors.purple,
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            if (narrow)
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  searchField,
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: filterDropdown,
                                  ),
                                ],
                              )
                            else
                              Row(
                                children: <Widget>[
                                  Expanded(child: searchField),
                                  const SizedBox(width: 12),
                                  filterDropdown,
                                ],
                              ),
                            if (_message.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 10),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  _message,
                                  style: const TextStyle(
                                    color: Color(0xFF475467),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (mapPoints.isNotEmpty &&
                        MediaQuery.sizeOf(context).height >= 700)
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 280,
                          child: RetailerMapView(
                            compact: true,
                            points: mapPoints,
                            hoveredId: _hoveredId,
                            selectedId: _selectedId,
                          ),
                        ),
                      ),
                    SliverToBoxAdapter(child: _proposalQueue()),
                    const SliverToBoxAdapter(child: Divider(height: 1)),
                    if (visible.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: Text('No retailers match this review filter.'),
                        ),
                      )
                    else
                      SliverList(
                        delegate: SliverChildBuilderDelegate((
                          BuildContext context,
                          int index,
                        ) {
                          if (index.isOdd) return const Divider(height: 1);
                          final _CoordinateRow row = visible[index ~/ 2];
                          final Widget actions = narrow
                              ? PopupMenuButton<String>(
                                  tooltip: 'Retailer actions',
                                  onSelected: (String action) {
                                    switch (action) {
                                      case 'map':
                                        _openMap(row);
                                        break;
                                      case 'review':
                                        _markReviewed(row);
                                        break;
                                      case 'edit':
                                        _edit(row);
                                        break;
                                    }
                                  },
                                  itemBuilder: (BuildContext context) =>
                                      <PopupMenuEntry<String>>[
                                        PopupMenuItem<String>(
                                          value: 'map',
                                          enabled:
                                              row.point != null ||
                                              row.address.isNotEmpty,
                                          child: const Text(
                                            'Open in Google Maps',
                                          ),
                                        ),
                                        PopupMenuItem<String>(
                                          value: 'review',
                                          enabled: row.point != null,
                                          child: const Text('Mark reviewed'),
                                        ),
                                        const PopupMenuItem<String>(
                                          value: 'edit',
                                          child: Text('Edit coordinates'),
                                        ),
                                      ],
                                )
                              : Wrap(
                                  spacing: 4,
                                  children: <Widget>[
                                    IconButton(
                                      tooltip: 'Open in Google Maps',
                                      onPressed:
                                          row.point == null &&
                                              row.address.isEmpty
                                          ? null
                                          : () => _openMap(row),
                                      icon: const Icon(Icons.map_outlined),
                                    ),
                                    IconButton(
                                      tooltip: 'Mark reviewed',
                                      onPressed: row.point == null
                                          ? null
                                          : () => _markReviewed(row),
                                      icon: const Icon(
                                        Icons.fact_check_outlined,
                                      ),
                                    ),
                                    FilledButton.tonalIcon(
                                      onPressed: () => _edit(row),
                                      icon: const Icon(Icons.edit_location_alt),
                                      label: const Text('Edit'),
                                    ),
                                  ],
                                );
                          return ListTile(
                            selected: row.id == _selectedId.value,
                            onTap: () => _selectedId.value = row.id,
                            leading: Icon(
                              row.issueCount == 0
                                  ? Icons.check_circle_outline
                                  : Icons.location_off_outlined,
                              color: row.issueCount == 0
                                  ? const Color(0xFF12B76A)
                                  : const Color(0xFFF79009),
                            ),
                            title: Text(
                              row.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${row.id} · ${row.coordinateText}\n'
                              '${row.issueLabel}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            isThreeLine: true,
                            trailing: actions,
                          );
                        }, childCount: visible.length * 2 - 1),
                      ),
                  ],
                );
              },
            ),
    );
  }

  Widget _summary(String label, int value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _proposalQueue() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _proposalStream,
      builder: (BuildContext context, AsyncSnapshot<List<Map<String, dynamic>>> snapshot) {
        if (snapshot.hasError) {
          return const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Field pin proposals unavailable'),
          );
        }
        final List<Map<String, dynamic>> proposals =
            snapshot.data ?? const <Map<String, dynamic>>[];
        if (proposals.isEmpty &&
            snapshot.connectionState == ConnectionState.active) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          height: proposals.isEmpty ? 68 : 230,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  'Field pin proposals${proposals.isEmpty ? '' : ' · ${proposals.length}'}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Expanded(
                child: proposals.isEmpty
                    ? const Center(child: Text('Loading field proposals…'))
                    : ListView.separated(
                        itemCount: proposals.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (BuildContext context, int index) {
                          final Map<String, dynamic> proposal =
                              proposals[index];
                          final String retailerId =
                              '${proposal['retailerId'] ?? ''}'.trim();
                          final _CoordinateRow? retailer = _rows
                              .where(
                                (_CoordinateRow row) => row.id == retailerId,
                              )
                              .firstOrNull;
                          final String name = retailer?.name ?? retailerId;
                          final String salesman =
                              '${proposal['salesmanCode'] ?? ''}'.trim();
                          final String point =
                              '${proposal['candidateLatitude']}, ${proposal['candidateLongitude']}';
                          return ListTile(
                            dense: true,
                            title: Text(
                              name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '$retailerId · $point${salesman.isEmpty ? '' : ' · $salesman'}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: widget.currentUser.isAdmin
                                ? MediaQuery.sizeOf(context).width < 600
                                      ? PopupMenuButton<String>(
                                          tooltip: 'Proposal actions',
                                          onSelected: (String action) =>
                                              _reviewProposal(
                                                proposal,
                                                approve: action == 'approve',
                                              ),
                                          itemBuilder: (BuildContext context) =>
                                              const <PopupMenuEntry<String>>[
                                                PopupMenuItem<String>(
                                                  value: 'reject',
                                                  child: Text('Reject'),
                                                ),
                                                PopupMenuItem<String>(
                                                  value: 'approve',
                                                  child: Text('Approve'),
                                                ),
                                              ],
                                        )
                                      : Wrap(
                                          spacing: 6,
                                          children: <Widget>[
                                            TextButton(
                                              onPressed: () => _reviewProposal(
                                                proposal,
                                                approve: false,
                                              ),
                                              child: const Text('Reject'),
                                            ),
                                            FilledButton.tonal(
                                              onPressed: () => _reviewProposal(
                                                proposal,
                                                approve: true,
                                              ),
                                              child: const Text('Approve'),
                                            ),
                                          ],
                                        )
                                : const Text('Pending review'),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CoordinateRow {
  const _CoordinateRow({
    required this.data,
    required this.point,
    required this.missing,
    required this.invalid,
    required this.needsReview,
    required this.duplicate,
  });

  final Map<String, dynamic> data;
  final LatLng? point;
  final bool missing;
  final bool invalid;
  final bool needsReview;
  final bool duplicate;

  String get id =>
      '${data['docId'] ?? data['retailerId'] ?? data['id'] ?? ''}'.trim();
  String get name =>
      '${data['retailerName'] ?? data['name'] ?? data['outletName'] ?? id}'
          .trim();
  String get address =>
      '${data['address'] ?? data['area'] ?? data['locationName'] ?? ''}'.trim();

  int get issueCount =>
      (missing ? 1 : 0) +
      (invalid ? 1 : 0) +
      (needsReview ? 1 : 0) +
      (duplicate ? 1 : 0);

  String get coordinateText => point == null
      ? 'No usable coordinate'
      : '${point!.latitude.toStringAsFixed(6)}, '
            '${point!.longitude.toStringAsFixed(6)}';

  String get issueLabel {
    final List<String> labels = <String>[
      if (missing) 'Missing coordinate fields',
      if (invalid) 'Coordinate fields are invalid',
      if (needsReview) 'Usable coordinate needs human review',
      if (duplicate) 'Same coordinate is used by another retailer',
    ];
    return labels.isEmpty ? 'Valid coordinate' : labels.join(' · ');
  }
}

String _coordinateKey(double lat, double lng) =>
    '${lat.toStringAsFixed(5)}|${lng.toStringAsFixed(5)}';
