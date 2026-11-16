import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/route_execution.dart';

void main() {
  Map<String, dynamic> legacyDoc({String status = 'completed'}) =>
      <String, dynamic>{
        'planId': 'route-1',
        'status': 'in_progress',
        'stopProgress': <String, dynamic>{
          'stop-1': <String, dynamic>{
            'stopId': 'stop-1',
            'retailerId': 'ret-1',
            'status': status,
          },
        },
      };

  Map<String, dynamic> stopDoc(String stopId, String retailerId) =>
      <String, dynamic>{
        'planId': 'route-1',
        'stopId': stopId,
        'retailerId': retailerId,
        'status': 'arrived',
        'arrivedAt': DateTime.utc(2026, 6, 22, 1),
      };

  test('a legacy-only document still yields its stop events', () {
    final List<StopExecutionEvent> events = mapProgressDocToEvents(legacyDoc());
    expect(events, hasLength(1));
    expect(events.single.stopId, 'stop-1');
    expect(events.single.status, 'completed');
  });

  test('a per-stop document is added even when the map has no entry', () {
    final List<StopExecutionEvent> events = mapProgressDocToEvents(
      legacyDoc(),
      stopDocuments: <Map<String, dynamic>>[stopDoc('stop-2', 'ret-2')],
    );
    expect(
      events.map((StopExecutionEvent e) => e.stopId),
      containsAll(<String>['stop-1', 'stop-2']),
    );
  });
}
