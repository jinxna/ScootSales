import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/utils/stop_arrival_identity.dart';

void main() {
  test('the document id binds plan, salesman and stop', () {
    expect(
      StopArrivalIdentity.documentId(
        planId: 'route-own',
        salesmanUid: 'sales-1',
        stopId: 'stop-1',
      ),
      'route-own_sales-1_stop-1',
    );
  });

  test('the event id is stable for the same arrival', () {
    final String first = StopArrivalIdentity.eventId(
      planId: 'route-own',
      stopId: 'stop-1',
    );
    final String second = StopArrivalIdentity.eventId(
      planId: 'route-own',
      stopId: 'stop-1',
    );
    expect(first, second);
    expect(first, 'route-own_stop-1_arrival');
    expect(StopArrivalIdentity.isAcceptableEventId(first), isTrue);
  });

  test('a slash in an input cannot split the document path', () {
    expect(
      StopArrivalIdentity.documentId(
        planId: 'route/own',
        salesmanUid: 'sales/1',
        stopId: 'stop/1',
      ),
      'route%2Fown_sales%2F1_stop%2F1',
    );
  });
}
