import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:scoot_design_gallery/frames.dart';
import 'package:scoot_design_gallery/main.dart';

const String contrastFontFamily = 'Roboto';

Directory _materialFontsDir() {
  final String? root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final Directory dir = Directory('$root/bin/cache/artifacts/material_fonts');
    if (dir.existsSync()) {
      return dir;
    }
  }
  Directory current = File(Platform.resolvedExecutable).parent;
  while (current.parent.path != current.path) {
    if (current.uri.pathSegments.where((String s) => s.isNotEmpty).last ==
        'cache') {
      return Directory('${current.path}/artifacts/material_fonts');
    }
    current = current.parent;
  }
  throw StateError('Flutter material fonts folder not found.');
}

Future<void> _loadFonts() async {
  final Directory dir = _materialFontsDir();
  final Uint8List icons = File(
    '${dir.path}/materialicons-regular.otf',
  ).readAsBytesSync();
  final FontLoader material = FontLoader('MaterialIcons')
    ..addFont(Future<ByteData>.value(ByteData.sublistView(icons)));
  await material.load();

  Future<void> loadPackaged(String family, List<String> files) async {
    final FontLoader loader = FontLoader(family);
    for (final String file in files) {
      loader.addFont(
        rootBundle.load('packages/scoot_design/assets/fonts/$file'),
      );
    }
    await loader.load();
  }

  const List<String> roboto = <String>[
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
    'roboto-black.ttf',
  ];
  final FontLoader contrastFont = FontLoader(contrastFontFamily);
  for (final String name in roboto) {
    final Uint8List bytes = File('${dir.path}/$name').readAsBytesSync();
    contrastFont.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  }
  await contrastFont.load();

  await loadPackaged(ScootType.fontFamily, <String>[
    'inter/Inter-Regular.ttf',
    'inter/Inter-Medium.ttf',
    'inter/Inter-SemiBold.ttf',
    'inter/Inter-Bold.ttf',
  ]);
  await loadPackaged('packages/scoot_design/Lucide', <String>[
    'lucide/Lucide.ttf',
  ]);
  await loadPackaged(ScootType.monoFamily, <String>[
    'jetbrains_mono/JetBrainsMono-Regular.ttf',
    'jetbrains_mono/JetBrainsMono-Medium.ttf',
  ]);
}

Directory _outDir() {
  final String path =
      Platform.environment['SCOOT_GALLERY_DIR'] ?? 'build/gallery';
  return Directory(path)..createSync(recursive: true);
}

Future<void> _interact(WidgetTester tester, String id) async {
  if (id == 'dashboard-account-menu') {
    await tester.tap(find.text('E2E Admin'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
  if (id == 'dashboard-keyboard-focus') {
    final Finder helpIcon = find.descendant(
      of: find.byTooltip('Help and keyboard shortcuts'),
      matching: find.byType(Icon),
    );
    for (int i = 0; i < 40; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      if (Focus.of(tester.element(helpIcon)).hasFocus) {
        break;
      }
    }
    expect(Focus.of(tester.element(helpIcon)).hasFocus, isTrue);
  }
}

void main() {
  setUpAll(_loadFonts);

  test('the gallery resolves the packaged fonts', () async {
    final String manifest = await rootBundle.loadString('FontManifest.json');
    expect(manifest, contains(ScootType.fontFamily));
    expect(manifest, contains(ScootType.monoFamily));
  });

  Future<void> pumpScene(WidgetTester tester, String id) async {
    final GalleryScene scene = allScenes.firstWhere(
      (GalleryScene s) => s.id == id,
    );
    tester.view.physicalSize = scene.size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: scene.theme,
        home: SceneFrame(scene: scene),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('phone home KPI numbers share one top edge', (
    WidgetTester tester,
  ) async {
    await pumpScene(tester, 'phone-home-synced');
    final Set<double> tops =
        <String>['Outlets', 'Orders today', 'Visits left', 'Unsent drafts'].map(
          (String label) {
            return tester
                .getTopLeft(find.byKey(ValueKey<String>('kpi-$label')))
                .dy;
          },
        ).toSet();
    expect(tops, hasLength(1));
    expect(
      tester.getSize(find.text('Orders today')).height,
      greaterThan(24),
      reason: 'the long label must wrap for this check to mean anything',
    );
  });

  testWidgets('sign-off scene shows the sign-off card', (
    WidgetTester tester,
  ) async {
    await pumpScene(tester, 'phone-visit-sign-disabled');
    expect(find.text('Sign-off'), findsOneWidget);
    expect(find.text('Count the shelf'), findsNothing);
  });

  testWidgets('supervisor scene selects the page it shows', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await pumpScene(tester, 'dashboard-supervisor-read-only');
    expect(
      find.bySemanticsLabel(RegExp('Team orders.*current page')),
      findsOneWidget,
    );
    expect(find.text('Team orders'), findsWidgets);
    expect(find.text('All Orders'), findsNothing);
    semantics.dispose();
  });

  for (final GalleryScene scene in allScenes.where(
    (GalleryScene s) => s.surface == GallerySurface.phone,
  )) {
    testWidgets('${scene.id} fits at text scale 1.3', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = scene.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: scene.theme,
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: SceneFrame(scene: scene),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final GalleryScene scene in allScenes) {
    testWidgets('${scene.id} renders, meets contrast and target size', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      tester.view.physicalSize = scene.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final GlobalKey boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: scene.theme,
            home: SceneFrame(scene: scene),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await _interact(tester, scene.id);
      expect(tester.takeException(), isNull);

      final double target = scene.surface == GallerySurface.phone ? 44 : 40;
      await expectLater(
        tester,
        meetsGuideline(
          MinimumTapTargetGuideline(
            size: Size(target, target),
            link: 'BRIEF.md rule 5',
          ),
        ),
      );
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

      final RenderRepaintBoundary render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final ByteData? png = await tester.runAsync<ByteData?>(() async {
        final ui.Image image = await render.toImage(pixelRatio: 1);
        final ByteData? data = await image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        image.dispose();
        return data;
      });
      expect(png, isNotNull);
      File(
        '${_outDir().path}/${scene.id}.png',
      ).writeAsBytesSync(png!.buffer.asUint8List());

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: scene.themeFor(contrastFontFamily),
          home: SceneFrame(scene: scene, fontFamily: contrastFontFamily),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await _interact(tester, scene.id);
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(textContrastGuideline));

      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    });
  }
}
