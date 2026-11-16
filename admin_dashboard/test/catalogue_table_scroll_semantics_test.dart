import 'dart:ui' show CheckedState;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/widgets/catalogue/catalogue_column.dart';
import 'package:flutter_web_app/widgets/catalogue/catalogue_table.dart';
import 'package:flutter_web_app/widgets/catalogue/catalogue_view_state.dart';

void main() {
  testWidgets('first column stays fixed while the rest scrolls and the tick '
      'box keeps its own semantics', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final CatalogueViewState<String> state = CatalogueViewState<String>();
    final Set<String> ticked = <String>{};
    final List<CatalogueColumn<String>> columns = <CatalogueColumn<String>>[
      CatalogueColumn<String>(
        id: 'name',
        label: 'Name',
        width: 150,
        cell: (BuildContext c, String r) => Text('Name $r'),
      ),
      for (final String id in <String>['a', 'b', 'c', 'd'])
        CatalogueColumn<String>(
          id: id,
          label: id,
          width: 200,
          cell: (BuildContext c, String r) => Text('$id $r'),
        ),
      CatalogueColumn<String>(
        id: 'tick',
        label: 'In sheet',
        width: 82,
        interactive: true,
        cell: (BuildContext c, String r) => Semantics(
          container: true,
          excludeSemantics: true,
          label: 'Select $r',
          checked: ticked.contains(r),
          onTap: () => ticked.add(r),
          child: Checkbox(value: ticked.contains(r), onChanged: (_) {}),
        ),
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: CatalogueTable<String>(
              rows: const <String>['Alpha'],
              idOf: (String r) => r,
              labelOf: (String r) => r,
              columns: columns,
              state: state,
              selectable: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final SemanticsNode tick = tester.getSemantics(
      find.bySemanticsLabel('Select Alpha'),
    );
    expect(
      tick.getSemanticsData().flagsCollection.isChecked,
      CheckedState.isFalse,
    );
    expect(tick.getSemanticsData().hasAction(SemanticsAction.tap), true);
    expect(find.bySemanticsLabel(RegExp('^a Alpha')), findsNothing);

    final double nameX = tester.getTopLeft(find.text('Name Alpha')).dx;
    final double aX = tester.getTopLeft(find.text('a Alpha')).dx;
    await tester.drag(find.text('a Alpha'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Name Alpha')).dx, nameX);
    expect(tester.getTopLeft(find.text('a Alpha')).dx, lessThan(aX));
    handle.dispose();
  });

  testWidgets('after a sideways scroll the fixed checkbox selects the row and '
      'does not open it', (WidgetTester tester) async {
    final CatalogueViewState<String> state = CatalogueViewState<String>();
    final List<String> opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: CatalogueTable<String>(
              rows: const <String>['Alpha'],
              idOf: (String r) => r,
              labelOf: (String r) => r,
              columns: <CatalogueColumn<String>>[
                for (final String id in <String>['n', 'a', 'b', 'c', 'd'])
                  CatalogueColumn<String>(
                    id: id,
                    label: id,
                    width: 200,
                    cell: (BuildContext c, String r) => Text('$id $r'),
                  ),
              ],
              state: state,
              onOpen: opened.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.text('a Alpha'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();
    expect(state.selectedIds, <String>{'Alpha'});
    expect(opened, isEmpty);
  });
}
