import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/screens/overview_screen.dart';

void main() {
  test(
    'VP-07 Home does not show the Count step as reached when no count is saved for the visit',
    () {
      expect(
        resumablePersonalVisitProgress(progress: 2, hasCountDraft: false),
        1,
      );
      expect(
        resumablePersonalVisitProgress(progress: 2, hasCountDraft: true),
        2,
      );
      expect(
        resumablePersonalVisitProgress(progress: 3, hasCountDraft: false),
        3,
      );
      expect(
        resumablePersonalVisitProgress(progress: 4, hasCountDraft: false),
        4,
      );
    },
  );
}
