import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_web_app/pages/admin/views/retailer_score_sheet_page.dart';

void main() {
  final Timestamp sheetSavedAt = Timestamp(1000, 0);
  final Timestamp beforeSave = Timestamp(900, 0);
  final Timestamp afterSave = Timestamp(1100, 0);
  final Set<String> disabled = <String>{'B'};
  final Set<String> visible = <String>{'A'};

  test(
    'without a readable timestamp a product outside the visible list stays unticked',
    () {
      for (final Object? missing in <Object?>[null, 'x']) {
        expect(
          scoreSheetProductLoadsTicked(
            aliases: <String>['C'],
            disabledIds: disabled,
            hiddenIds: <String>{},
            visibleIds: visible,
            createdAt: missing,
            sheetUpdatedAt: sheetSavedAt,
          ),
          isFalse,
        );
        expect(
          scoreSheetProductLoadsTicked(
            aliases: <String>['C'],
            disabledIds: disabled,
            hiddenIds: <String>{},
            visibleIds: visible,
            createdAt: afterSave,
            sheetUpdatedAt: missing,
          ),
          isFalse,
        );
      }
    },
  );

  test(
    'a disabled product stays unticked even when created after the last save',
    () {
      expect(
        scoreSheetProductLoadsTicked(
          aliases: <String>['C'],
          disabledIds: <String>{'C'},
          hiddenIds: <String>{},
          visibleIds: visible,
          createdAt: afterSave,
          sheetUpdatedAt: sheetSavedAt,
        ),
        isFalse,
      );
    },
  );

  group('a save keeps products the editor never showed', () {
    final Set<String> shown = <String>{'A', 'B', 'E'};

    Map<String, dynamic> row(
      String id,
      Object? created, {
      bool visible = true,
    }) => <String, dynamic>{
      'docId': id,
      'createdAt': created,
      'isVisible': visible,
    };

    Map<String, List<String>> save({
      required List<Map<String, dynamic>> fresh,
      required Set<String> ticked,
      Set<String> loadedVisible = const <String>{'A', 'E'},
      Set<String> loadedDisabled = const <String>{'B'},
    }) {
      final Set<String> savedVisible = <String>{...ticked};
      final List<String> kept = scoreSheetUnseenProductsToKeep(
        freshProducts: fresh,
        shownIds: shown,
        disabledIds: loadedDisabled,
        hiddenIds: <String>{},
        visibleIds: loadedVisible,
        savedVisibleIds: savedVisible,
        sheetUpdatedAt: sheetSavedAt,
      );
      return <String, List<String>>{
        'visible': <String>{...savedVisible, ...kept}.toList(),
        'disabled': scoreSheetDisabledIds(
          retained: loadedDisabled,
          allProductIds: shown.toList(),
          selectedProductIds: ticked,
        ),
      };
    }

    test(
      'a product created hidden and published later is already on the sheet',
      () {
        final Map<String, List<String>> saved = save(
          fresh: <Map<String, dynamic>>[row('D', afterSave, visible: false)],
          ticked: <String>{'A', 'E'},
        );

        expect(saved['visible'], contains('D'));
        expect(saved['disabled'], isNot(contains('D')));
      },
    );

    test('a product the admin saw and left unticked is still disabled', () {
      final Map<String, List<String>> saved = save(
        fresh: <Map<String, dynamic>>[row('E', afterSave), row('C', afterSave)],
        ticked: <String>{'A'},
      );

      expect(saved['disabled'], containsAll(<String>['B', 'E']));
      expect(saved['visible'], isNot(contains('E')));
      expect(saved['visible'], contains('C'));
    });

    test('an unseen product older than the sheet stays off', () {
      final Map<String, List<String>> saved = save(
        fresh: <Map<String, dynamic>>[row('F', beforeSave)],
        ticked: <String>{'A', 'E'},
      );

      expect(saved['visible'], isNot(contains('F')));
      expect(saved['disabled'], isNot(contains('F')));
    });

    test('a list that saves empty stays empty', () {
      final Map<String, List<String>> saved = save(
        fresh: <Map<String, dynamic>>[row('C', afterSave)],
        ticked: <String>{},
        loadedVisible: <String>{},
      );

      expect(saved['visible'], isEmpty);
    });

    test('an unseen product without a readable creation time is not added', () {
      for (final Object? missing in <Object?>[null, 'x']) {
        final Map<String, List<String>> saved = save(
          fresh: <Map<String, dynamic>>[row('C', missing)],
          ticked: <String>{'A', 'E'},
        );

        expect(saved['visible'], isNot(contains('C')));
      }
    });

    test('a disabled, hidden or demo unseen product is not added', () {
      final List<String> kept = scoreSheetUnseenProductsToKeep(
        freshProducts: <Map<String, dynamic>>[
          row('G', afterSave),
          row('H', afterSave),
          <String, dynamic>{...row('I', afterSave), 'isDemo': true},
        ],
        shownIds: shown,
        disabledIds: <String>{'G'},
        hiddenIds: <String>{'H'},
        visibleIds: <String>{'A'},
        savedVisibleIds: <String>{'A'},
        sheetUpdatedAt: sheetSavedAt,
      );

      expect(kept, isEmpty);
    });

    test('a sheet that had no visible list keeps every unseen product on', () {
      final List<String> kept = scoreSheetUnseenProductsToKeep(
        freshProducts: <Map<String, dynamic>>[row('F', beforeSave)],
        shownIds: shown,
        disabledIds: <String>{},
        hiddenIds: <String>{},
        visibleIds: <String>{},
        savedVisibleIds: <String>{'A'},
        sheetUpdatedAt: null,
      );

      expect(kept, <String>['F']);
    });
  });
}
