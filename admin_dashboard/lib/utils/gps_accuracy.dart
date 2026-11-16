const double lowAccuracyMeters = 100;

bool isLowAccuracy(num meters) => meters > lowAccuracyMeters;

String accuracyText(num meters) {
  final String base = '±${meters.round()} m';
  return isLowAccuracy(meters) ? '$base (low accuracy)' : base;
}

const String gpsRetentionNote =
    'Location history is kept for 30 days and older points are removed '
    'automatically, so an empty history is not a fault.';
