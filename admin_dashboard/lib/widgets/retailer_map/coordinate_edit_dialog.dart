import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../utils/retailer_coordinate_edit.dart';

class CoordinateEditOutcome {
  const CoordinateEditOutcome({required this.verified, required this.payload});

  final bool verified;
  final Map<String, dynamic> payload;
}

Future<CoordinateEditOutcome?> showCoordinateEditDialog(
  BuildContext context, {
  required Map<String, dynamic> retailer,
  required String retailerName,
  required String address,
  required String initialLatitude,
  required String initialLongitude,
  required String reviewerUid,
  Object? reviewedAt,
}) async {
  final TextEditingController latController = TextEditingController(
    text: initialLatitude,
  );
  final TextEditingController lngController = TextEditingController(
    text: initialLongitude,
  );
  String? validation;
  void validateAndPop(
    BuildContext dialogContext,
    StateSetter setDialogState,
    String mode,
  ) {
    final double? lat = double.tryParse(latController.text.trim());
    final double? lng = double.tryParse(lngController.text.trim());
    if (!_validCoordinate(lat, lng)) {
      setDialogState(() {
        validation =
            'Enter a non-zero latitude (-90 to 90) and longitude '
            '(-180 to 180).';
      });
      return;
    }
    Navigator.pop(dialogContext, mode);
  }

  String? save = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => StatefulBuilder(
      builder: (BuildContext context, StateSetter setDialogState) =>
          AlertDialog(
            title: Text('Review $retailerName'),
            content: SizedBox(
              width: 430,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    address.isEmpty ? 'No address saved.' : address,
                    style: const TextStyle(color: Color(0xFF667085)),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: latController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Latitude'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: lngController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Longitude'),
                  ),
                  if (validation != null) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      validation!,
                      style: const TextStyle(color: Color(0xFFB42318)),
                    ),
                  ],
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              OutlinedButton(
                onPressed: () =>
                    validateAndPop(dialogContext, setDialogState, 'candidate'),
                child: const Text('Save as candidate (needs review)'),
              ),
              FilledButton(
                onPressed: () =>
                    validateAndPop(dialogContext, setDialogState, 'verify'),
                child: const Text('Save & mark verified'),
              ),
            ],
          ),
    ),
  );
  if (save == 'verify' && context.mounted) {
    if (!await _confirmVerify(context, retailerName)) save = null;
  }
  final String latText = latController.text.trim();
  final String lngText = lngController.text.trim();
  latController.dispose();
  lngController.dispose();
  if (save == null) return null;
  final double lat = double.parse(latText);
  final double lng = double.parse(lngText);
  if (save == 'verify') {
    return CoordinateEditOutcome(
      verified: true,
      payload: verifiedCoordinatePayload(
        original: retailer,
        latitudeText: lat.toString(),
        longitudeText: lng.toString(),
        reviewerUid: reviewerUid,
        reviewedAt: reviewedAt ?? FieldValue.serverTimestamp(),
      ),
    );
  }
  return CoordinateEditOutcome(
    verified: false,
    payload: retailerCoordinateEdit(
      latitudeText: lat.toString(),
      longitudeText: lng.toString(),
      original: retailer,
      forceCanonical: true,
    ),
  );
}

Future<bool> _confirmVerify(BuildContext context, String name) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text('Mark $name verified?'),
      content: const Text(
        'This marks the location verified and makes the retailer '
        'route-ready.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Mark verified'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

bool _validCoordinate(double? lat, double? lng) {
  if (lat == null || lng == null) return false;
  if (!lat.isFinite || !lng.isFinite) return false;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return false;
  return !(lat == 0 && lng == 0);
}
