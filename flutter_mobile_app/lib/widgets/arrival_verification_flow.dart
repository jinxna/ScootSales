import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../models/assigned_route_plan.dart';
import '../providers/gps_provider.dart';
import '../services/route_plan_service.dart';
import '../utils/location_evidence.dart';

Future<StopArrivalEvidence?> collectSelectedStopArrivalEvidence(
  BuildContext context, {
  required AssignedRoutePlan plan,
  required AssignedRouteStop stop,
  required RouteProgress progress,
  required bool isOnline,
}) async {
  if (progress.selectedStopId != stop.stopId) {
    throw StateError(selectStopBeforeArrivalMessage);
  }
  return collectStopArrivalEvidence(
    context,
    stop,
    isOnline: isOnline,
    publishedSnapshotAt: plan.publishedAt,
  );
}

Future<StopArrivalEvidence?> collectStopArrivalEvidence(
  BuildContext context,
  AssignedRouteStop stop, {
  bool isOnline = true,
  DateTime? publishedSnapshotAt,
}) async {
  final RetailerCoordinateSnapshot? published = stop.retailerCoordinateSnapshot;
  final DateTime? snapshotAt = published?.referenceTime(publishedSnapshotAt);
  final bool canCheckPublishedSnapshotOffline =
      published?.isVerified == true && snapshotAt != null;
  if (!isOnline) {
    if (canCheckPublishedSnapshotOffline) {
      final _OfflineArrivalChoice?
      choice = await showDialog<_OfflineArrivalChoice>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('Check arrival against published pin'),
          content: Text(
            'You are offline. A fresh GPS fix can be checked against the verified pin saved with this route. This records the pin revision, source, and snapshot time; it does not check for later retailer-pin changes.\n\n'
            'Revision: ${published!.coordinateRevision}\n'
            'Source: ${published.coordinateSource}\n'
            'Snapshot time: ${snapshotAt.toLocal()}\n\n'
            'The fix must still be within 75 m, no older than 30 seconds, and accurate to 25 m or better.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _OfflineArrivalChoice.manual),
              child: const Text('Record unverified'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                _OfflineArrivalChoice.checkSnapshot,
              ),
              child: const Text('Check GPS'),
            ),
          ],
        ),
      );
      if (!context.mounted || choice == null) return null;
      if (choice == _OfflineArrivalChoice.manual) {
        return _collectManualArrival(
          context,
          const ArrivalLocationAssessment.unavailable(
            LocationEvidenceFailure.unavailable,
          ),
        );
      }
    } else {
      final bool? continueUnverified = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('Offline arrival'),
          content: const Text(
            'This route has no verified coordinate snapshot with a usable reference time. Without an online canonical retailer check, only an unverified manual arrival can be recorded.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Record unverified'),
            ),
          ],
        ),
      );
      if (continueUnverified != true || !context.mounted) return null;
      return _collectManualArrival(
        context,
        const ArrivalLocationAssessment.unavailable(
          LocationEvidenceFailure.unavailable,
        ),
      );
    }
  }

  while (true) {
    if (!context.mounted) return null;
    final _ArrivalCheckResult? result = await showDialog<_ArrivalCheckResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _LocationCaptureDialog(
        stop: stop,
        isOnline: isOnline,
        publishedSnapshotAt: publishedSnapshotAt,
      ),
    );
    if (result == null || !context.mounted) return null;
    final ArrivalLocationAssessment assessment = result.assessment;
    if (assessment.isVerified) {
      return StopArrivalEvidence.verified(
        assessment,
        currentRetailerCoordinatesVerified: true,
        coordinateReferenceMode: result.resolution!.coordinateReferenceMode,
        retailerCoordinateRevision: result.resolution!.coordinateRevision,
        retailerCoordinateSource: result.resolution!.coordinateSource,
        coordinateSnapshotAt: result.resolution!.coordinateSnapshotAt,
        coordinateCheckedAt: result.resolution!.coordinateCheckedAt,
      );
    }

    final _UnverifiedChoice? choice = await showDialog<_UnverifiedChoice>(
      context: context,
      builder: (BuildContext dialogContext) {
        final double? distance = assessment.distanceMeters;
        return AlertDialog(
          title: const Text('Arrival not verified'),
          content: Text(
            '${assessment.failure!.userMessage}'
            '${distance == null ? '' : '\n\nMeasured distance: ${distance.round()} m.'}'
            '${result.retailerMessage.isEmpty ? '' : '\n\n${result.retailerMessage}'}'
            '\n\nYou can retry, or record a clearly labelled manual arrival for manager review.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _UnverifiedChoice.retry),
              child: const Text('Retry GPS'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _UnverifiedChoice.manual),
              child: const Text('Record unverified'),
            ),
          ],
        );
      },
    );
    if (choice == _UnverifiedChoice.retry) continue;
    if (choice != _UnverifiedChoice.manual || !context.mounted) return null;

    return _collectManualArrival(context, assessment);
  }
}

enum _OfflineArrivalChoice { checkSnapshot, manual }

enum _UnverifiedChoice { retry, manual }

Future<StopArrivalEvidence?> _collectManualArrival(
  BuildContext context,
  ArrivalLocationAssessment assessment,
) async {
  final _ManualArrivalInput? input = await showDialog<_ManualArrivalInput>(
    context: context,
    builder: (_) => const _ManualArrivalDialog(),
  );
  if (input == null || !context.mounted) return null;
  return StopArrivalEvidence.manual(
    assessment: assessment,
    reason: input.reason,
    note: input.note,
  );
}

class _LocationCaptureDialog extends StatefulWidget {
  const _LocationCaptureDialog({
    required this.stop,
    required this.isOnline,
    required this.publishedSnapshotAt,
  });

  final AssignedRouteStop stop;
  final bool isOnline;
  final DateTime? publishedSnapshotAt;

  @override
  State<_LocationCaptureDialog> createState() => _LocationCaptureDialogState();
}

class _LocationCaptureDialogState extends State<_LocationCaptureDialog> {
  @override
  void initState() {
    super.initState();
    _capture();
  }

  Future<void> _capture() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (!mounted) return;
        Navigator.pop(
          context,
          const _ArrivalCheckResult(
            assessment: ArrivalLocationAssessment.unavailable(
              LocationEvidenceFailure.serviceDisabled,
            ),
            retailerMessage:
                'Turn on Location in your phone settings, then retry.',
          ),
        );
        return;
      }
      final _RetailerPinResolution resolution =
          await _resolveCurrentVerifiedRetailerPin(
            widget.stop,
            isOnline: widget.isOnline,
            publishedSnapshotAt: widget.publishedSnapshotAt,
          );
      if (!mounted) return;
      if (resolution.failure != null) {
        Navigator.pop(
          context,
          _ArrivalCheckResult(
            assessment: ArrivalLocationAssessment.unavailable(
              resolution.failure!,
            ),
            retailerMessage: resolution.message,
          ),
        );
        return;
      }
      final ArrivalLocationAssessment assessment = await context
          .read<GpsProvider>()
          .captureArrivalLocation(
            retailerLatitude: resolution.latitude!,
            retailerLongitude: resolution.longitude!,
          );
      String preciseHint = '';
      if (!assessment.isVerified) {
        try {
          if (await Geolocator.getLocationAccuracy() ==
              LocationAccuracyStatus.reduced) {
            preciseHint =
                'Approximate location is on. Turn on Precise location for this app in phone settings, then retry.';
          }
        } catch (_) {}
      }
      if (mounted) {
        Navigator.pop(
          context,
          _ArrivalCheckResult(
            assessment: assessment,
            resolution: resolution,
            retailerMessage: preciseHint,
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      Navigator.pop(
        context,
        const _ArrivalCheckResult(
          assessment: ArrivalLocationAssessment.unavailable(
            LocationEvidenceFailure.unavailable,
          ),
          retailerMessage:
              'The current retailer pin or GPS fix could not be checked. Check the connection and try again, or record an unverified arrival.',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text('Checking retailer pin and GPS'),
        content: Row(
          children: <Widget>[
            SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 14),
            Expanded(
              child: Text(
                'Checking the current retailer pin, then getting a fresh fix…',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArrivalCheckResult {
  const _ArrivalCheckResult({
    required this.assessment,
    this.resolution,
    this.retailerMessage = '',
  });

  final ArrivalLocationAssessment assessment;
  final _RetailerPinResolution? resolution;
  final String retailerMessage;
}

class _RetailerPinResolution {
  const _RetailerPinResolution.success({
    required this.latitude,
    required this.longitude,
    required this.coordinateReferenceMode,
    required this.coordinateRevision,
    required this.coordinateSource,
    required this.coordinateSnapshotAt,
    required this.coordinateCheckedAt,
  }) : failure = null,
       message = '';

  const _RetailerPinResolution.failure(this.failure, this.message)
    : latitude = null,
      longitude = null,
      coordinateReferenceMode = 'unverified',
      coordinateRevision = '',
      coordinateSource = '',
      coordinateSnapshotAt = null,
      coordinateCheckedAt = null;

  final double? latitude;
  final double? longitude;
  final LocationEvidenceFailure? failure;
  final String message;
  final String coordinateReferenceMode;
  final String coordinateRevision;
  final String coordinateSource;
  final DateTime? coordinateSnapshotAt;
  final DateTime? coordinateCheckedAt;
}

Future<_RetailerPinResolution> _resolveCurrentVerifiedRetailerPin(
  AssignedRouteStop stop, {
  required bool isOnline,
  DateTime? publishedSnapshotAt,
}) async {
  final RetailerCoordinateSnapshot? published = stop.retailerCoordinateSnapshot;
  if (published != null && !published.isVerified) {
    return const _RetailerPinResolution.failure(
      LocationEvidenceFailure.missingRetailerCoordinates,
      'This published retailer pin is marked as a candidate or needs review. Ask an administrator to refresh the route.',
    );
  }
  final String retailerId = stop.retailerId.trim();
  if (retailerId.isEmpty) {
    return const _RetailerPinResolution.failure(
      LocationEvidenceFailure.missingRetailerCoordinates,
      'This stop has no canonical retailer ID, so its pin cannot be checked.',
    );
  }

  if (!isOnline) {
    final DateTime? snapshotAt = published?.referenceTime(publishedSnapshotAt);
    if (published == null ||
        !published.isVerified ||
        published.coordinateRevision.trim().isEmpty ||
        published.coordinateSource.trim().isEmpty ||
        snapshotAt == null) {
      return const _RetailerPinResolution.failure(
        LocationEvidenceFailure.missingRetailerCoordinates,
        'This route has no verified retailer pin snapshot with a revision, source, and reference time. GPS confirmation is unavailable offline; record an unverified arrival instead.',
      );
    }
    return _RetailerPinResolution.success(
      latitude: published.latitude!,
      longitude: published.longitude!,
      coordinateReferenceMode: 'published_snapshot_offline',
      coordinateRevision: published.coordinateRevision,
      coordinateSource: published.coordinateSource,
      coordinateSnapshotAt: snapshotAt,
      coordinateCheckedAt: null,
    );
  }

  Map<String, dynamic> retailer;
  try {
    final DocumentSnapshot<Map<String, dynamic>> snapshot =
        await FirebaseFirestore.instance
            .collection('retailers')
            .doc(retailerId)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 6));
    if (!snapshot.exists || snapshot.data() == null) {
      return const _RetailerPinResolution.failure(
        LocationEvidenceFailure.missingRetailerCoordinates,
        'The current retailer record is unavailable. Refresh the route or record an unverified arrival.',
      );
    }
    retailer = snapshot.data()!;
  } on FirebaseException catch (error) {
    if (error.code == 'permission-denied') {
      return const _RetailerPinResolution.failure(
        LocationEvidenceFailure.unavailable,
        'This retailer record is not in your branch or assigned to you, so its pin cannot be checked. Ask your admin to set the retailer branch, or record an unverified arrival.',
      );
    }
    return const _RetailerPinResolution.failure(
      LocationEvidenceFailure.unavailable,
      'The current retailer record could not be checked from the server. Check the connection or record an unverified arrival.',
    );
  } catch (_) {
    return const _RetailerPinResolution.failure(
      LocationEvidenceFailure.unavailable,
      'The current retailer record could not be checked from the server. Check the connection or record an unverified arrival.',
    );
  }

  try {
    final RetailerCoordinateSnapshot? current =
        RetailerCoordinateSnapshot.fromRetailerRecord(retailerId, retailer);
    if (current == null || !current.isVerified) {
      return const _RetailerPinResolution.failure(
        LocationEvidenceFailure.missingRetailerCoordinates,
        'The current retailer pin is missing, invalid, a candidate, or needs review. GPS arrival confirmation is disabled.',
      );
    }

    if (published != null) {
      final String publishedRevision = published.coordinateRevision.trim();
      final String currentRevision = current.coordinateRevision;
      if (publishedRevision.isEmpty ||
          currentRevision.isEmpty ||
          publishedRevision != currentRevision ||
          published.latitude != current.latitude ||
          published.longitude != current.longitude) {
        return const _RetailerPinResolution.failure(
          LocationEvidenceFailure.missingRetailerCoordinates,
          'The current retailer pin has changed since this route was published. Ask an administrator to refresh the route.',
        );
      }
    }

    return _RetailerPinResolution.success(
      latitude: current.latitude!,
      longitude: current.longitude!,
      coordinateReferenceMode: 'current_retailer',
      coordinateRevision: current.coordinateRevision,
      coordinateSource: current.coordinateSource,
      coordinateSnapshotAt: published?.referenceTime(publishedSnapshotAt),
      coordinateCheckedAt: DateTime.now().toUtc(),
    );
  } catch (_) {
    return const _RetailerPinResolution.failure(
      LocationEvidenceFailure.missingRetailerCoordinates,
      'The retailer pin has an unsupported or invalid coordinate shape. GPS arrival confirmation is disabled.',
    );
  }
}

class _ManualArrivalInput {
  const _ManualArrivalInput(this.reason, this.note);

  final ManualArrivalReason reason;
  final String note;
}

class _ManualArrivalDialog extends StatefulWidget {
  const _ManualArrivalDialog();

  @override
  State<_ManualArrivalDialog> createState() => _ManualArrivalDialogState();
}

class _ManualArrivalDialogState extends State<_ManualArrivalDialog> {
  final TextEditingController _noteController = TextEditingController();
  ManualArrivalReason _reason = ManualArrivalReason.gpsUnavailable;
  String _error = '';

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  void _save() {
    final String note = _noteController.text.trim();
    if (note.length < 3) {
      setState(
        () => _error = 'Add a short explanation (at least 3 characters).',
      );
      return;
    }
    if (note.length > 300) {
      setState(() => _error = 'Keep the explanation within 300 characters.');
      return;
    }
    Navigator.pop(context, _ManualArrivalInput(_reason, note));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Record unverified arrival'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'This will not count as a GPS-verified arrival. A manager should review it.',
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<ManualArrivalReason>(
              initialValue: _reason,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Reason',
                border: OutlineInputBorder(),
              ),
              items: ManualArrivalReason.values
                  .map(
                    (ManualArrivalReason value) => DropdownMenuItem(
                      value: value,
                      child: Text(value.label, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (ManualArrivalReason? value) {
                if (value != null) setState(() => _reason = value);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              minLines: 2,
              maxLines: 4,
              maxLength: 300,
              decoration: InputDecoration(
                labelText: 'Explanation',
                hintText: 'What prevented GPS verification?',
                border: const OutlineInputBorder(),
                errorText: _error.isEmpty ? null : _error,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save unverified')),
      ],
    );
  }
}
