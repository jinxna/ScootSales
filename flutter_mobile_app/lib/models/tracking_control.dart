enum TrackingMode {
  live(
    'live',
    'Live',
    movingIntervalSeconds: 30,
    stationaryIntervalSeconds: 60,
    staleAfterSeconds: 180,
  ),
  standard(
    'standard',
    'Standard',
    movingIntervalSeconds: 60,
    stationaryIntervalSeconds: 120,
    staleAfterSeconds: 300,
  ),
  batterySaver(
    'battery_saver',
    'Battery saver',
    movingIntervalSeconds: 180,
    stationaryIntervalSeconds: 300,
    staleAfterSeconds: 660,
  );

  const TrackingMode(
    this.wireValue,
    this.label, {
    required this.movingIntervalSeconds,
    required this.stationaryIntervalSeconds,
    required this.staleAfterSeconds,
  });

  final String wireValue;
  final String label;
  final int movingIntervalSeconds;
  final int stationaryIntervalSeconds;
  final int staleAfterSeconds;

  static TrackingMode? tryParse(Object? value) {
    for (final TrackingMode mode in values) {
      if (mode.wireValue == value) return mode;
    }
    return null;
  }
}

class TrackingControl {
  const TrackingControl({
    required this.mode,
    required this.revision,
    this.updatedByUid = '',
    this.updatedAt,
  });

  const TrackingControl.defaultValue()
    : mode = TrackingMode.batterySaver,
      revision = 0,
      updatedByUid = '',
      updatedAt = null;

  final TrackingMode mode;
  final int revision;
  final String updatedByUid;
  final DateTime? updatedAt;

  factory TrackingControl.fromMap(Map<String, dynamic> data) {
    final TrackingMode? mode = TrackingMode.tryParse(data['mode']);
    final Object? rawRevision = data['revision'];
    final Object? rawUpdatedByUid = data['updatedByUid'];
    if (mode == null ||
        rawRevision is! int ||
        rawRevision < 1 ||
        rawUpdatedByUid is! String ||
        rawUpdatedByUid.trim().isEmpty) {
      throw const FormatException('Tracking control has an invalid shape.');
    }
    final Object? rawUpdatedAt = data['updatedAt'];
    final DateTime? updatedAt = rawUpdatedAt is DateTime
        ? rawUpdatedAt.toUtc()
        : null;
    return TrackingControl(
      mode: mode,
      revision: rawRevision,
      updatedByUid: rawUpdatedByUid.trim(),
      updatedAt: updatedAt,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'mode': mode.wireValue,
    'revision': revision,
    'updatedByUid': updatedByUid,
    'updatedAt': updatedAt,
  };
}
