import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/widgets/location_status_banner.dart';

String textFor(Object error) =>
    stopSaveFailureMessage(error, fallback: 'fallback');

void main() {
  test('a skip refused by the service shows plain words', () {
    expect(
      textFor(StateError('A terminal stop cannot be skipped again.')),
      'This stop is already finished.',
    );
    expect(
      textFor(StateError('The stop is no longer pending.')),
      'This stop is already finished.',
    );
    expect(
      textFor(StateError('Completion requires a prior accepted arrival.')),
      'Mark arrival at this stop first.',
    );
  });
}
