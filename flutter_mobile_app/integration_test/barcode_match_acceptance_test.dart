import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:scoot_design/scoot_design.dart' show ScootBottomNav;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:fmcg_sales/main.dart' as app;
import 'package:fmcg_sales/screens/add_to_cart.dart';
import 'package:fmcg_sales/screens/barcode_scanner_screen.dart';
import 'package:fmcg_sales/screens/order_cart_screen.dart';

const String _retailerId = 'barcode-match-acceptance-retailer';
const String _retailerName = 'Barcode Match Acceptance Retailer';
const String _category = 'BARCODE ACCEPTANCE';
const String _searchHint = 'Search SKU or product...';

class _Product {
  const _Product(this.id, this.name, this.barcode, {this.barcodeField});

  final String id;
  final String name;

  final String? barcode;

  final String? barcodeField;
}

const _Product _plain = _Product(
  'bcm-plain',
  'Barcode Accept Plain Biscuit',
  '9551111222233',
  barcodeField: 'itemBarcode',
);
const _Product _spaced = _Product(
  'bcm-spaced',
  'Barcode Accept Spaced Oat',
  '955 1234 5678',
  barcodeField: 'itemBarcode',
);
const _Product _zero = _Product(
  'bcm-zero',
  'Barcode Accept Zero Rice',
  '0012345',
  barcodeField: 'itemBarcode',
);
const _Product _dash = _Product(
  'bcm-dash',
  'Barcode Accept Dash Tea',
  '9-55-777',
  barcodeField: 'itemBarcode',
);
const _Product _number = _Product(
  'bcm-number',
  'Barcode Accept Number Salt',
  '9557001234',
  barcodeField: 'barcode',
);
const _Product _noBarcode = _Product(
  'bcm-empty',
  'Barcode Accept Empty Sugar',
  null,
);

const List<_Product> _products = <_Product>[
  _plain,
  _spaced,
  _zero,
  _dash,
  _number,
  _noBarcode,
];

class _Scan {
  const _Scan(this.label, this.value, this.expected);

  final String label;
  final String value;

  final _Product? expected;
}

const List<_Scan> _scans = <_Scan>[
  _Scan('plain_digits', '9551111222233', _plain),
  _Scan('stored_spaces', '95512345678', _spaced),
  _Scan('dots_in_scan', '955.1234.5678', _spaced),
  _Scan('leading_zeros', '0012345', _zero),
  _Scan('leading_zeros_kept', '12345', null),
  _Scan('stored_hyphens', '955777', _dash),
  _Scan('number_typed_in_firestore', '9557001234', _number),
  _Scan('unknown_code', '000111222', null),
  _Scan('separators_only_vs_empty_product_barcode', '-', null),
];

Map<String, Object?> _productFields(_Product product) {
  final String? barcode = product.barcode;
  return <String, Object?>{
    'productId': <String, Object?>{'stringValue': product.id},
    'itemName': <String, Object?>{'stringValue': product.name},
    'productName': <String, Object?>{'stringValue': product.name},
    'itemCode': <String, Object?>{'stringValue': product.id},
    'packingSize': <String, Object?>{'stringValue': '24 X 500ML'},
    'unitPrice': <String, Object?>{'doubleValue': 9.5},
    'brandName': <String, Object?>{'stringValue': 'TENTEN'},
    'departmentName': <String, Object?>{'stringValue': _category},
    'mainCategoryName': <String, Object?>{'stringValue': _category},
    'sortOrder': <String, Object?>{'integerValue': '0'},
    'isVisible': <String, Object?>{'booleanValue': true},
    if (barcode != null && product.barcodeField == 'barcode')
      'barcode': <String, Object?>{'integerValue': barcode}
    else if (barcode != null)
      'itemBarcode': <String, Object?>{'stringValue': barcode},
  };
}

Future<void> _emulatorRequest(
  String method,
  String url,
  Map<String, Object?>? body,
) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.openUrl(
      method,
      Uri.parse(url),
    );
    request.headers
      ..set('Content-Type', 'application/json')
      ..set('Authorization', 'Bearer owner');
    if (body != null) request.write(jsonEncode(body));
    final HttpClientResponse response = await request.close();
    final String text = await utf8.decodeStream(response);
    if (response.statusCode >= 300) {
      fail('Emulator $method failed (${response.statusCode}): $text');
    }
  } finally {
    client.close(force: true);
  }
}

void _traceStage(String stage) {
  // ignore: avoid_print
  print('BARCODE_MATCH_STAGE $stage');
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  required Duration timeout,
  required String label,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $label.');
}

Future<void> _waitGone(
  WidgetTester tester,
  Finder finder, {
  required Duration timeout,
  required String label,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isEmpty) return;
  }
  fail('Timed out waiting for $label to go away.');
}

void _clearSnackBars(WidgetTester tester) {
  ScaffoldMessenger.of(
    tester.element(find.byType(Scaffold).last),
  ).clearSnackBars();
}

Finder get _searchField => find.byWidgetPredicate(
  (Widget widget) =>
      widget is TextField && widget.decoration?.hintText == _searchHint,
);

String _searchText(WidgetTester tester) =>
    tester.widget<TextField>(_searchField).controller?.text ?? '';

Future<void> _openScanner(WidgetTester tester) async {
  _clearSnackBars(tester);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byIcon(Icons.qr_code_scanner));
  await _waitFor(
    tester,
    find.byType(MobileScanner),
    timeout: const Duration(seconds: 20),
    label: 'the scanner screen',
  );
}

void _detect(WidgetTester tester, List<String?> rawValues) {
  final MobileScanner scanner = tester.widget<MobileScanner>(
    find.byType(MobileScanner),
  );
  for (final String? raw in rawValues) {
    scanner.onDetect!(
      BarcodeCapture(barcodes: <Barcode>[Barcode(rawValue: raw)]),
    );
  }
}

Future<void> _finishScan(WidgetTester tester) async {
  await _waitGone(
    tester,
    find.byType(BarcodeScannerScreen),
    timeout: const Duration(seconds: 10),
    label: 'the scanner screen',
  );
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _scan(WidgetTester tester, String value) async {
  await _openScanner(tester);
  _detect(tester, <String?>[value]);
  await _finishScan(tester);
}

Set<String> _pickerChecked(WidgetTester tester) => <String>{
  for (final CheckboxListTile tile in tester.widgetList<CheckboxListTile>(
    find.byType(CheckboxListTile),
  ))
    if (tile.value == true) (tile.title! as Text).data!,
};

Finder _pickerRow(String name) => find.widgetWithText(CheckboxListTile, name);

void _expectCartShows(Iterable<_Product> shown) {
  final Set<String> names = shown.map((_Product p) => p.name).toSet();
  for (final _Product product in _products) {
    expect(
      find.text(product.name),
      names.contains(product.name) ? findsOneWidget : findsNothing,
      reason: 'cart row for ${product.id}',
    );
  }
}

Future<void> _clearSearch(WidgetTester tester) async {
  final Finder close = find.descendant(
    of: _searchField,
    matching: find.byIcon(Icons.close),
  );
  if (close.evaluate().isNotEmpty) {
    await tester.tap(close.first);
    await tester.pump(const Duration(milliseconds: 300));
  }
  expect(_searchText(tester), isEmpty);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the same scan selects the same product in the picker and the cart',
    (WidgetTester tester) async {
      const bool useFirebaseEmulator = bool.fromEnvironment(
        'USE_FIREBASE_EMULATOR',
      );
      const String firebaseEmulatorHost = String.fromEnvironment(
        'FIREBASE_EMULATOR_HOST',
      );
      const int firestorePort = int.fromEnvironment('FIRESTORE_EMULATOR_PORT');
      expect(useFirebaseEmulator, isTrue);
      expect(firebaseEmulatorHost, '10.0.2.2');
      expect(firestorePort, greaterThan(0));

      const MethodChannel scannerMethods = MethodChannel(
        'dev.steenbakker.mobile_scanner/scanner/method',
      );
      const MethodChannel scannerEvents = MethodChannel(
        'dev.steenbakker.mobile_scanner/scanner/event',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        scannerMethods,
        (MethodCall call) async {
          switch (call.method) {
            case 'state':
              return 1;
            case 'start':
              return <String, Object?>{
                'textureId': 1,
                'numberOfCameras': 1,
                'currentTorchState': -1,
                'size': <String, Object?>{'width': 640.0, 'height': 480.0},
              };
            default:
              return null;
          }
        },
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        scannerEvents,
        (MethodCall call) async => null,
      );

      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          scannerMethods,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          scannerEvents,
          null,
        );
      });

      app.main();
      await tester.pump(const Duration(seconds: 2));
      final Finder quickSignIn = find.text('Salesperson');
      final Finder assignedRouteEntry = find.descendant(
        of: find.byType(ScootBottomNav),
        matching: find.text('Route'),
      );
      final DateTime loginDeadline = DateTime.now().add(
        const Duration(seconds: 60),
      );
      while (DateTime.now().isBefore(loginDeadline) &&
          quickSignIn.evaluate().isEmpty &&
          assignedRouteEntry.evaluate().isEmpty) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      if (quickSignIn.evaluate().isNotEmpty) {
        await tester.tap(quickSignIn.first);
      }
      await _waitFor(
        tester,
        assignedRouteEntry,
        timeout: const Duration(seconds: 90),
        label: 'the authenticated salesperson home',
      );
      expect(FirebaseAuth.instance.currentUser?.uid, isNotEmpty);
      _traceStage('authenticated_home');
      final String documents =
          'http://$firebaseEmulatorHost:$firestorePort/v1/projects/'
          '${FirebaseFirestore.instance.app.options.projectId}'
          '/databases/(default)/documents/products';
      addTearDown(() async {
        await tester.runAsync(() async {
          for (final _Product product in _products) {
            await _emulatorRequest('DELETE', '$documents/${product.id}', null);
          }
        });
      });
      await tester.runAsync(() async {
        for (final _Product product in _products) {
          await _emulatorRequest('PATCH', '$documents/${product.id}', {
            'fields': _productFields(product),
          });
        }
      });
      _traceStage('products_seeded');

      final NavigatorState navigator = Navigator.of(
        tester.element(assignedRouteEntry.first),
      );

      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const AddToCartPage(
              retailerId: _retailerId,
              retailerName: _retailerName,
            ),
          ),
        ),
      );
      await _waitFor(
        tester,
        find.text(_category),
        timeout: const Duration(seconds: 60),
        label: 'the acceptance products in the picker',
      );
      _traceStage('picker_open');

      final Set<String> expectedChecked = <String>{};
      for (final _Scan scan in _scans) {
        await _scan(tester, scan.value);
        final _Product? expected = scan.expected;
        if (expected == null) {
          expect(
            find.text('Barcode ${scan.value} not found for this retailer.'),
            findsOneWidget,
            reason: 'picker ${scan.label}',
          );
        } else {
          expectedChecked.add(expected.name);
          expect(
            find.text('Selected: ${expected.name}'),
            findsOneWidget,
            reason: 'picker ${scan.label}',
          );
          expect(
            _pickerRow(expected.name),
            findsOneWidget,
            reason: 'picker ${scan.label}: matched row must be visible',
          );
        }
        expect(
          _pickerChecked(tester),
          expectedChecked,
          reason: 'picker ${scan.label}: exactly one action per scan',
        );
        _traceStage('picker_${scan.label}');
      }
      expect(_pickerChecked(tester), isNot(contains(_noBarcode.name)));

      await _openScanner(tester);
      _detect(tester, <String?>['', null]);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(BarcodeScannerScreen), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(BarcodeScannerScreen),
          matching: find.byIcon(Icons.close),
        ),
      );
      await _finishScan(tester);
      expect(_pickerChecked(tester), expectedChecked);
      expect(find.textContaining('Selected:'), findsNothing);
      expect(find.textContaining('not found'), findsNothing);
      _traceStage('picker_empty_and_cancel_do_nothing');

      await _openScanner(tester);
      _detect(tester, <String?>['777888999', _zero.barcode, _dash.barcode]);
      await _finishScan(tester);
      expect(find.byType(AddToCartPage), findsOneWidget);
      expect(find.textContaining('Selected:'), findsNothing);
      expect(
        find.text('Barcode 777888999 not found for this retailer.'),
        findsOneWidget,
      );
      expect(_pickerChecked(tester), expectedChecked);
      _traceStage('picker_repeated_detection_one_action');

      await tester.enterText(_searchField, '955-1234');
      await tester.pump(const Duration(milliseconds: 300));
      expect(_pickerRow(_spaced.name), findsOneWidget);
      expect(_pickerRow(_plain.name), findsNothing);
      await tester.enterText(_searchField, '~~');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('No products found'), findsOneWidget);
      await tester.enterText(_searchField, '9551234');
      await tester.pump(const Duration(milliseconds: 300));
      expect(_pickerRow(_plain.name), findsNothing);
      await _scan(tester, _plain.barcode!);
      expect(_searchText(tester), isEmpty);
      expect(_pickerRow(_plain.name), findsOneWidget);
      _traceStage('picker_search_by_barcode_and_filter_cleared');

      await tester.tap(find.byIcon(Icons.home_outlined));
      await tester.pump(const Duration(seconds: 1));
      await _waitFor(
        tester,
        assignedRouteEntry,
        timeout: const Duration(seconds: 10),
        label: 'the home screen after the picker',
      );
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => OrderCartScreen(
              selectedItems: _products
                  .map(
                    (_Product p) => <String, dynamic>{
                      'productId': p.id,
                      'name': p.name,
                    },
                  )
                  .toList(),
              retailerId: _retailerId,
              retailerName: _retailerName,
            ),
          ),
        ),
      );
      await _waitFor(
        tester,
        find.text(_products.last.name),
        timeout: const Duration(seconds: 60),
        label: 'the cart rows',
      );
      _expectCartShows(_products);
      _traceStage('cart_open');

      for (final _Scan scan in _scans) {
        await _scan(tester, scan.value);
        final _Product? expected = scan.expected;
        if (expected == null) {
          expect(
            find.text('Barcode ${scan.value} not found in cart.'),
            findsOneWidget,
            reason: 'cart ${scan.label}',
          );
          expect(_searchText(tester), isEmpty, reason: 'cart ${scan.label}');
          _expectCartShows(_products);
        } else {
          expect(
            find.text('Found: ${expected.name}'),
            findsOneWidget,
            reason: 'cart ${scan.label}',
          );
          expect(
            _searchText(tester),
            expected.barcode,
            reason: 'cart ${scan.label}: search box holds the stored barcode',
          );
          _expectCartShows(<_Product>[expected]);
          await _clearSearch(tester);
          _expectCartShows(_products);
        }
        _traceStage('cart_${scan.label}');
      }

      await _openScanner(tester);
      _detect(tester, <String?>['', null]);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(BarcodeScannerScreen), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(BarcodeScannerScreen),
          matching: find.byIcon(Icons.close),
        ),
      );
      await _finishScan(tester);
      expect(_searchText(tester), isEmpty);
      expect(find.textContaining('Found:'), findsNothing);
      expect(find.textContaining('not found'), findsNothing);
      _expectCartShows(_products);
      _traceStage('cart_empty_and_cancel_do_nothing');

      await _openScanner(tester);
      _detect(tester, <String?>[_zero.barcode, _dash.barcode, _plain.barcode]);
      await _finishScan(tester);
      expect(find.byType(OrderCartScreen), findsOneWidget);
      expect(find.text('Found: ${_zero.name}'), findsOneWidget);
      expect(find.textContaining('Found:'), findsOneWidget);
      _expectCartShows(<_Product>[_zero]);
      await _clearSearch(tester);
      _traceStage('cart_repeated_detection_one_action');

      await tester.enterText(_searchField, '955-1234');
      await tester.pump(const Duration(milliseconds: 300));
      _expectCartShows(<_Product>[_spaced]);
      await tester.enterText(_searchField, _number.barcode!.substring(2));
      await tester.pump(const Duration(milliseconds: 300));
      _expectCartShows(<_Product>[_number]);
      await tester.enterText(_searchField, '~~');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('No matching items.'), findsOneWidget);
      _expectCartShows(const <_Product>[]);
      await _clearSearch(tester);
      _traceStage('cart_search_by_barcode');

      // ignore: avoid_print
      print(
        'BARCODE_MATCH_TRACE ${jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'fixture': 'barcode-match-acceptance-v1',
          'emulatorOnly': true,
          'cameraUsed': false,
          'scanSource': 'real_MobileScanner_onDetect_callback',
          'scenarios': _scans.map((_Scan s) => s.label).toList(),
          'pickerAndCartAgreeOnEveryScenario': true,
          'oneActionPerScan': true,
          'repeatedDetectionOnePop': true,
          'emptyDetectionIgnored': true,
          'cancelDoesNothing': true,
          'matchedRowVisibleAfterScan': true,
          'unverifiedBoundaries': <String>['real_camera_decode', 'scan_speed', 'dim_or_damaged_labels'],
        })}',
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
