import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scoot_design/scoot_design.dart';

double _contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Map<String, (Color, Color)> _textPairs(ScootColors c) {
  final Map<String, (Color, Color)> pairs = <String, (Color, Color)>{
    'ink on page': (c.ink, c.page),
    'ink on card': (c.ink, c.card),
    'text2 on card': (c.text2, c.card),
    'muted on page': (c.muted, c.page),
    'muted on card': (c.muted, c.card),
    'muted on search': (c.muted, c.searchFill),
    'table head text': (c.tableHeadText, c.tableHead),
    'onBrand on brand': (c.onBrand, c.brand),
    'onBrand on brand hover': (c.onBrand, c.brandHover),
    'brand text on tint': (c.brandText, c.brandTint),
    'brand text on card': (c.brandText, c.card),
    'nav text on rail': (c.navText, c.navBg),
    'nav label on rail': (c.navLabel, c.navBg),
    'nav text on hover': (c.navText, c.navHover),
    'white on nav on': (const Color(0xFFFFFFFF), c.navOn),
    'count badge': (c.countText, c.countBg),
    'disabled text on disabled fill': (c.disabledText, c.disabledFill),
    'disabled text on card': (c.disabledText, c.card),
  };
  for (final ScootTone tone in ScootTone.values) {
    final ScootToneColors t = c.tone(tone);
    pairs['${tone.name} badge'] = (t.foreground, t.background);
    pairs['${tone.name} note'] = (t.noteText, t.noteBackground);
  }
  return pairs;
}

Widget _app(Widget child, {ScootSurface surface = ScootSurface.dashboard}) {
  return MaterialApp(
    theme: ScootTheme.build(surface: surface, fontFamily: null),
    home: Scaffold(body: child),
  );
}

void main() {
  for (final ScootColors colors in <ScootColors>[
    ScootColors.light,
    ScootColors.dark,
  ]) {
    test('${colors.brightness.name} text pairs reach 4.5:1', () {
      final List<String> failing = <String>[
        for (final MapEntry<String, (Color, Color)> e in _textPairs(
          colors,
        ).entries)
          if (_contrast(e.value.$1, e.value.$2) < 4.5)
            '${e.key} ${_contrast(e.value.$1, e.value.$2).toStringAsFixed(2)}',
      ];
      expect(failing, isEmpty);
    });
  }

  testWidgets('loading shows Still loading only after 10 s, Retry restarts', (
    WidgetTester tester,
  ) async {
    int retries = 0;
    await tester.pumpWidget(
      _app(
        ScootLoadingState(
          onRetry: () => retries++,
          skeleton: const ScootSkeleton(height: 120),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 9));
    expect(find.textContaining('Still loading'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Still loading'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retries, 1);
    expect(find.textContaining('Still loading'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(find.textContaining('Still loading'), findsOneWidget);
  });

  testWidgets('table keeps its header when empty and pages by 50', (
    WidgetTester tester,
  ) async {
    int loads = 0;
    final List<ScootTableColumn<int>> columns = <ScootTableColumn<int>>[
      ScootTableColumn<int>(
        label: 'Order ID',
        cell: (BuildContext context, int row) => Text('ORD-$row'),
      ),
    ];
    Widget table(List<int> rows) => _app(
      ScootDataTable<int>(
        columns: columns,
        rows: rows,
        phase: ScootLoadPhase.ready,
        onRetry: () {},
        emptyTitle: 'No orders yet',
        hasMore: true,
        onLoadMore: () => loads++,
      ),
    );
    await tester.pumpWidget(table(const <int>[]));
    expect(find.text('Order ID'), findsOneWidget);
    expect(find.text('No orders yet'), findsOneWidget);
    await tester.pumpWidget(table(List<int>.generate(50, (int i) => i)));
    expect(find.text('50 rows · 50 per page'), findsOneWidget);
    await tester.tap(find.text('Load 50 more'));
    expect(loads, 1);
  });

  testWidgets('Ctrl K opens the command palette from the shell', (
    WidgetTester tester,
  ) async {
    int opened = 0;
    await tester.pumpWidget(
      _app(
        ScootDashboardShell(
          rail: const SizedBox(width: 10),
          topBar: const SizedBox(height: 10),
          onCommandPalette: () => opened++,
          child: const SizedBox(),
        ),
      ),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(opened, 1);
  });

  test('banner priority and GPS thresholds follow the shell notes', () {
    const ScootActionBannerData rejected = ScootActionBannerData(
      priority: ScootBannerPriority.rejectedOrder,
      title: 'Rejected',
    );
    const ScootActionBannerData paused = ScootActionBannerData(
      priority: ScootBannerPriority.companyPaused,
      title: 'Paused',
    );
    expect(
      ScootActionBanner.pick(<ScootActionBannerData>[rejected, paused]),
      same(paused),
    );
    expect(ScootActionBanner.pick(const <ScootActionBannerData>[]), isNull);
    expect(ScootGpsStatus.fix(0).label, 'GPS accuracy unknown');
    expect(ScootGpsStatus.fix(50).kind, ScootGpsKind.good);
    expect(ScootGpsStatus.fix(51).label, 'GPS weak ±51 m');
  });

  testWidgets('step bar announces the current step', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(const ScootStepBar(current: 1), surface: ScootSurface.phone),
    );
    expect(find.bySemanticsLabel('Step 2 of 3, Count'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('count badge sizes to its content in a stretched column', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ScootCountBadge(count: 4, semanticLabel: '4 waiting'),
            ScootCountBadge(count: 150, semanticLabel: 'many waiting'),
          ],
        ),
      ),
    );
    final List<Size> sizes = tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: find.byType(ScootCountBadge),
            matching: find.byType(DecoratedBox),
          ),
        )
        .map((DecoratedBox b) => tester.getSize(find.byWidget(b)))
        .toList();
    expect(sizes, hasLength(2));
    for (final Size size in sizes) {
      expect(size.width, lessThan(60));
    }
  });

  testWidgets('icon buttons draw the focus ring when focused', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        Column(
          children: <Widget>[
            ScootTopBar(
              onSearch: () {},
              scopeLabel: 'All branches',
              onHelp: () {},
              account: const ScootAccount(name: 'Admin', subtitle: 'Admin'),
              accountActions: const <ScootMenuAction>[],
            ),
            ScootNotice(
              tone: ScootTone.info,
              message: 'Saved.',
              onDismiss: () {},
            ),
            ScootPhoneAppBar(title: 'Orders', onBack: () {}),
          ],
        ),
        surface: ScootSurface.phone,
      ),
    );
    bool? ringShown(String tooltip) {
      final Finder ring = find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(ScootFocusRing),
      );
      if (ring.evaluate().isEmpty) {
        return null;
      }
      final Finder paint = find.descendant(
        of: ring.first,
        matching: find.byType(CustomPaint),
      );
      return tester.widget<CustomPaint>(paint.first).foregroundPainter != null;
    }

    for (final String tooltip in <String>[
      'Help and keyboard shortcuts',
      'Dismiss',
      'Back',
    ]) {
      expect(ringShown(tooltip), isFalse, reason: '$tooltip before focus');
      final Element icon = tester.element(
        find.descendant(
          of: find.byTooltip(tooltip),
          matching: find.byType(Icon),
        ),
      );
      Focus.of(icon).requestFocus();
      await tester.pump();
      expect(ringShown(tooltip), isTrue, reason: '$tooltip focused');
      Focus.of(icon).unfocus();
      await tester.pump();
    }
  });

  testWidgets('bottom nav and step bar fit at text scale 1.3', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ScootTheme.phone(fontFamily: null),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              const ScootStepBar(current: 1),
              const Spacer(),
              ScootBottomNav(
                current: ScootPhoneTab.home,
                ordersWaiting: 2,
                onSelect: (ScootPhoneTab tab) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only notice says Read-only once', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        Column(
          children: <Widget>[
            ScootNotice.readOnly(),
            ScootNotice.readOnly(message: 'Only an admin can change orders.'),
          ],
        ),
      ),
    );
    final Finder texts = find.textContaining('Read-only', findRichText: true);
    expect(texts, findsNWidgets(2));
    for (final RichText text in tester.widgetList<RichText>(texts)) {
      expect('Read-only'.allMatches(text.text.toPlainText()), hasLength(1));
    }
  });

  testWidgets('role changed notice ends with an OK button', (
    WidgetTester tester,
  ) async {
    int closed = 0;
    await tester.pumpWidget(
      _app(
        ScootNotice.roleChanged(
          roleName: 'Supervisor',
          pagesLabel: 'supervisor',
          onDismiss: () => closed++,
        ),
      ),
    );
    expect(find.text('OK'), findsOneWidget);
    expect(find.byType(IconButton), findsNothing);
    await tester.tap(find.text('OK'));
    expect(closed, 1);
  });

  testWidgets('still loading bar sits above the skeleton, not over it', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        ScootLoadingState(
          onRetry: () {},
          skeleton: const ScootSkeleton(key: Key('skeleton'), height: 120),
        ),
      ),
    );
    await tester.pump(ScootTiming.stillLoadingAfter);
    final Rect bar = tester.getRect(find.byType(ScootStillLoadingBar));
    final Rect skeleton = tester.getRect(find.byKey(const Key('skeleton')));
    expect(skeleton.top, greaterThanOrEqualTo(bar.bottom));
  });

  testWidgets('offline strip shows the kept text on two lines at 390 px', (
    WidgetTester tester,
  ) async {
    final FontLoader inter = FontLoader('Inter');
    for (final String weight in <String>['Regular', 'SemiBold', 'Bold']) {
      final Uint8List bytes = File(
        'assets/fonts/inter/Inter-$weight.ttf',
      ).readAsBytesSync();
      inter.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    }
    await inter.load();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ScootTheme.phone(fontFamily: 'Inter'),
        home: Scaffold(
          body: ScootStatusStrip(
            sync: const ScootSyncStatus.offline('2 orders kept on this phone.'),
            gps: ScootGpsStatus.fix(65),
            onTap: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      find.textContaining('kept on this phone', findRichText: true),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('table footer adds live when the list updates live', (
    WidgetTester tester,
  ) async {
    Widget table({required bool live}) => _app(
      ScootDataTable<int>(
        columns: <ScootTableColumn<int>>[
          ScootTableColumn<int>(
            label: 'Order ID',
            cell: (BuildContext context, int row) => Text('ORD-$row'),
          ),
        ],
        rows: const <int>[1, 2],
        phase: ScootLoadPhase.ready,
        onRetry: () {},
        emptyTitle: 'No orders yet',
        live: live,
      ),
    );
    await tester.pumpWidget(table(live: false));
    expect(find.text('2 rows · 50 per page'), findsOneWidget);
    await tester.pumpWidget(table(live: true));
    expect(find.text('2 rows · 50 per page · live'), findsOneWidget);
  });

  testWidgets('table on a 390 phone shows every column with its label', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<String> tapped = <String>[];
    await tester.pumpWidget(
      _app(
        Padding(
          padding: const EdgeInsets.all(16),
          child: ScootDataTable<String>(
            columns: <ScootTableColumn<String>>[
              ScootTableColumn<String>(
                label: 'Name',
                flex: 3,
                cell: (BuildContext context, String row) => Text(row),
              ),
              ScootTableColumn<String>(
                label: 'Code',
                width: 120,
                cell: (BuildContext context, String row) => const Text('S001'),
              ),
              ScootTableColumn<String>(
                label: 'Role',
                width: 150,
                cell: (BuildContext context, String row) =>
                    const Text('Salesman'),
              ),
              ScootTableColumn<String>(
                label: 'Status',
                width: 110,
                cell: (BuildContext context, String row) =>
                    const Text('Active'),
              ),
            ],
            rows: const <String>['Aisyah Rahman'],
            phase: ScootLoadPhase.ready,
            onRetry: () {},
            emptyTitle: 'No people match',
            onRowTap: tapped.add,
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final Finder name = find.text('Aisyah Rahman');
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      name,
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.getSize(name).width, greaterThan(60));
    for (final String label in <String>['Name', 'Code', 'Role', 'Status']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Active'), findsOneWidget);
    await tester.tap(name);
    expect(tapped, <String>['Aisyah Rahman']);
  });

  testWidgets('table renders at most pageSize rows per loaded page', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget table({int pagesLoaded = 1}) => _app(
      ScootDataTable<int>(
        columns: <ScootTableColumn<int>>[
          ScootTableColumn<int>(
            label: 'Order ID',
            cell: (BuildContext context, int row) => Text('ORD-$row'),
          ),
        ],
        rows: List<int>.generate(120, (int i) => i),
        phase: ScootLoadPhase.ready,
        onRetry: () {},
        emptyTitle: 'No orders yet',
        hasMore: true,
        pagesLoaded: pagesLoaded,
      ),
    );
    await tester.pumpWidget(table());
    expect(find.textContaining('ORD-'), findsNWidgets(50));
    expect(find.text('50 rows · 50 per page'), findsOneWidget);
    await tester.pumpWidget(table(pagesLoaded: 2));
    expect(find.textContaining('ORD-'), findsNWidgets(100));
  });

  testWidgets('grey notes keep their button below the note, full width', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ScootNotice.roleChanged(
              roleName: 'Supervisor',
              pagesLabel: 'supervisor',
              onDismiss: () {},
            ),
            ScootStillLoadingBar(message: 'Still loading.', onRetry: () {}),
          ],
        ),
      ),
    );
    final Color grey = ScootColors.light.neutral.noteBackground;
    final List<Finder> pairs = <Finder>[find.text('OK'), find.text('Retry')];
    final List<Finder> notes = <Finder>[
      find.textContaining('Your role changed'),
      find.textContaining('Still loading.'),
    ];
    for (int i = 0; i < 2; i++) {
      final Finder box = find.ancestor(
        of: notes[i],
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).color == grey,
        ),
      );
      expect(box, findsOneWidget);
      final Rect noteRect = tester.getRect(box);
      final Rect button = tester.getRect(
        find.ancestor(of: pairs[i], matching: find.byType(OutlinedButton)),
      );
      expect(button.top, greaterThanOrEqualTo(noteRect.bottom));
      expect(button.width, noteRect.width);
    }
  });

  testWidgets(
    'primary action bar with icon and secondary fits 320 at text scale 1.3',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ScootTheme.phone(fontFamily: null),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ScootPrimaryActionBar(
                label: 'Resume order',
                icon: ScootIcons.play,
                onPressed: () {},
                secondaryLabel: 'Discard draft',
                onSecondary: () {},
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Resume order'), findsOneWidget);
      expect(find.text('Discard draft'), findsOneWidget);
    },
  );

  testWidgets('ScootPhoneScaffold keeps content out of side cut-outs', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ScootTheme.phone(fontFamily: null),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 400),
            padding: EdgeInsets.only(left: 48, right: 48),
          ),
          child: ScootPhoneScaffold(
            appBar: AppBar(title: const Text('Title')),
            body: const SizedBox.expand(key: Key('side-body')),
            primaryAction: const SizedBox(key: Key('side-action'), height: 40),
          ),
        ),
      ),
    );
    final Rect body = tester.getRect(find.byKey(const Key('side-body')));
    final Rect action = tester.getRect(find.byKey(const Key('side-action')));
    expect(body.left, greaterThanOrEqualTo(48));
    expect(body.right, lessThanOrEqualTo(752));
    expect(action.left, greaterThanOrEqualTo(48));
    expect(action.right, lessThanOrEqualTo(752));
  });
}
