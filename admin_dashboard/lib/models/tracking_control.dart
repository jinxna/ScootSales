import 'package:cloud_firestore/cloud_firestore.dart';

enum TrackingUploadMode {
  live(
    'live',
    'Live',
    '30 s moving / 60 s stationary',
    Duration(seconds: 30),
    3,
  ),
  standard(
    'standard',
    'Standard',
    '60 s moving / 120 s stationary',
    Duration(seconds: 60),
    5,
  ),
  batterySaver(
    'battery_saver',
    'Battery saver',
    '180 s moving / 300 s stationary',
    Duration(seconds: 180),
    11,
  );

  const TrackingUploadMode(
    this.wireValue,
    this.label,
    this.cadenceLabel,
    this.movingInterval,
    this.staleMinutes,
  );

  final String wireValue;
  final String label;
  final String cadenceLabel;
  final Duration movingInterval;
  final int staleMinutes;

  static TrackingUploadMode? tryParse(Object? value) {
    for (final TrackingUploadMode mode in values) {
      if (mode.wireValue == value) return mode;
    }
    return null;
  }
}

class TrackingControl {
  const TrackingControl({
    required this.mode,
    required this.revision,
    required this.updatedByUid,
    this.updatedAt,
  });

  const TrackingControl.defaultValue()
    : mode = TrackingUploadMode.batterySaver,
      revision = 0,
      updatedByUid = '',
      updatedAt = null;

  final TrackingUploadMode mode;
  final int revision;
  final String updatedByUid;
  final DateTime? updatedAt;

  static TrackingControl fromDocument(
    DocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    if (!snapshot.exists) return const TrackingControl.defaultValue();
    final Map<String, dynamic> data = snapshot.data() ?? <String, dynamic>{};
    final TrackingUploadMode? mode = TrackingUploadMode.tryParse(data['mode']);
    final Object? revision = data['revision'];
    final Object? updatedByUid = data['updatedByUid'];
    if (mode == null ||
        revision is! int ||
        revision < 1 ||
        updatedByUid is! String ||
        updatedByUid.trim().isEmpty) {
      throw const FormatException('Tracking control has an invalid shape.');
    }
    final Object? rawUpdatedAt = data['updatedAt'];
    final DateTime? updatedAt = rawUpdatedAt is Timestamp
        ? rawUpdatedAt.toDate().toUtc()
        : rawUpdatedAt is DateTime
        ? rawUpdatedAt.toUtc()
        : null;
    return TrackingControl(
      mode: mode,
      revision: revision,
      updatedByUid: updatedByUid.trim(),
      updatedAt: updatedAt,
    );
  }
}
