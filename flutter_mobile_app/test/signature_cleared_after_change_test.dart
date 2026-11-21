import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/providers/auth_provider.dart';
import 'package:fmcg_sales/providers/gps_provider.dart';
import 'package:fmcg_sales/screens/order_signature_screen.dart';
import 'package:fmcg_sales/services/cart_draft_cache.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

const String _changed = 'Changed after signing. Ask the shop to sign again.';
const String _unsigned = '1 department still needs a signature';

Map<String, dynamic> _signature({String? lines}) => <String, dynamic>{
  'points': <Map<String, num>>[
    <String, num>{'dx': 1, 'dy': 1},
    <String, num>{'dx': 9, 'dy': 9},
  ],
  'signed': true,
  'signedAt': DateTime(2026, 11, 9).millisecondsSinceEpoch,
  'lines': ?lines,
};

String _keyFor(String visitId) =>
    CartDraftCache.keyFor(salesmanUid: 'u1', retailerId: 'r1', visitId: visitId);

Future<void> _pumpScreen(WidgetTester tester, String visitId) async {
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      key: UniqueKey(),
      providers: <ChangeNotifierProvider<ChangeNotifier>>[
        ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider()),
        ChangeNotifierProvider<GpsProvider>(create: (_) => GpsProvider()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: OrderSignatureScreen(
            visitId: visitId,
            cartItems: <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'Soap',
                'productId': '',
                'department': 'Other',
                'qty': 2,
                'price': 1.0,
                'retailerId': 'r1',
                'retailerName': 'Shop',
                'visitId': visitId,
              },
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<String> _openSavedSignature(
  WidgetTester tester, {
  required String visitId,
  required Map<String, dynamic> signature,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  signInTestUser('u1');
  final String key = _keyFor(visitId);
  CartDraftCache.save(
    key,
    CartDraftSnapshot(
      salesmanUid: 'u1',
      retailerId: 'r1',
      visitId: visitId,
      progress: 4,
      pendingOrderId: 'o1',
      signatures: <String, Map<String, dynamic>>{'Other': signature},
    ),
  );
  await _pumpScreen(tester, visitId);
  return key;
}

Future<String> _openAndSign(
  WidgetTester tester, {
  required String visitId,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  signInTestUser('u1');
  final String key = _keyFor(visitId);
  CartDraftCache.save(
    key,
    CartDraftSnapshot(
      salesmanUid: 'u1',
      retailerId: 'r1',
      visitId: visitId,
      progress: 4,
      pendingOrderId: 'o1',
    ),
  );
  await _pumpScreen(tester, visitId);
  expect(find.text(_unsigned), findsOneWidget);
  final Finder pad = find.text('Sign here');
  await tester.ensureVisible(pad);
  await tester.pump();
  await tester.drag(pad, const Offset(30, 8));
  await tester.pump();
  expect(find.text(_unsigned), findsNothing);
  expect(find.text(_changed), findsNothing);
  expect(_saved(key)['signed'], isTrue);
  return key;
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30));
}

Map<String, dynamic> _saved(String key) =>
    CartDraftCache.read(key)!.signatures['Other']!;

SignatureOrderItem _line() => SignatureOrderItem(
  no: 1,
  productName: 'Soap',
  productId: 'p1',
  packingSize: '12 x 100G',
  uom: 'box',
  maxOrderQty: 5,
  unitPrice: 1.5,
  priceSource: '',
  orderQty: 2,
  stockOnShelf: 0,
  department: 'Other',
  shelfBatches: <Map<String, dynamic>>[],
  orderedExpiry: '1/12/2026',
  remarks: 'front shelf',
);

void main() {
  setUpAll(installTestFirebase);

  for (final (String path, Future<void> Function(WidgetTester) change)
      in <(String, Future<void> Function(WidgetTester))>[
        (
          'plus',
          (WidgetTester tester) async {
            await tester.ensureVisible(find.byIcon(Icons.add));
            await tester.tap(find.byIcon(Icons.add));
          },
        ),
        (
          'minus to zero',
          (WidgetTester tester) async {
            await tester.ensureVisible(find.byIcon(Icons.remove));
            await tester.tap(find.byIcon(Icons.remove));
            await tester.pump();
            await tester.tap(find.byIcon(Icons.remove));
          },
        ),
        (
          'typed quantity',
          (WidgetTester tester) async {
            final Finder field = find.widgetWithText(TextField, '2');
            await tester.ensureVisible(field);
            await tester.enterText(field, '5');
          },
        ),
        (
          'a changed remark',
          (WidgetTester tester) async {
            final Finder field = find.widgetWithText(
              TextField,
              'Add notes for this product…',
            );
            await tester.ensureVisible(field);
            await tester.enterText(field, 'deliver to the back door');
          },
        ),
        (
          'a changed expiry date',
          (WidgetTester tester) async {
            final Finder expiry = find.text('Select Ordered Batch Expiry');
            await tester.ensureVisible(expiry);
            await tester.pump();
            await tester.tap(expiry);
            await tester.pump();
            await tester.pump(const Duration(seconds: 1));
            await tester.tap(find.text('OK'));
            await tester.pump();
            await tester.pump(const Duration(seconds: 1));
            expect(find.text('Select Ordered Batch Expiry'), findsNothing);
          },
        ),
      ]) {
    testWidgets('a signed department loses its signature after $path', (
      WidgetTester tester,
    ) async {
      final String key = await _openAndSign(tester, visitId: 'v-$path');

      await change(tester);
      await tester.pump();

      expect(find.text(_changed), findsOneWidget);
      expect(find.text(_unsigned), findsOneWidget);
      expect(_saved(key)['signed'], isFalse);
      expect(_saved(key)['signedAt'], isNull);
      expect(_saved(key)['points'], isEmpty);
      await _close(tester);
    });
  }

  testWidgets('plus then minus does not bring the signature back', (
    WidgetTester tester,
  ) async {
    final String key = await _openAndSign(tester, visitId: 'v-back');
    await tester.ensureVisible(find.byIcon(Icons.add));
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.remove));
    await tester.pump();

    expect(find.text(_changed), findsOneWidget);
    expect(find.text(_unsigned), findsOneWidget);
    expect(_saved(key)['signed'], isFalse);
    await _close(tester);
  });

  testWidgets('typing the same quantity keeps the signature', (
    WidgetTester tester,
  ) async {
    final String key = await _openAndSign(tester, visitId: 'v-same');
    final Finder field = find.widgetWithText(TextField, '2');
    await tester.ensureVisible(field);
    await tester.enterText(field, '2');
    await tester.pump();

    expect(find.text(_changed), findsNothing);
    expect(find.text(_unsigned), findsNothing);
    expect(_saved(key)['signed'], isTrue);
    await _close(tester);
  });

  testWidgets(
    'a signature is still there when the same order is opened again',
    (WidgetTester tester) async {
      final String key = await _openAndSign(tester, visitId: 'v-reopen');
      await _close(tester);

      await _pumpScreen(tester, 'v-reopen');

      expect(find.text(_changed), findsNothing);
      expect(find.text(_unsigned), findsNothing);
      expect(find.text('Sign here'), findsNothing);
      expect(_saved(key)['signed'], isTrue);
      await _close(tester);
    },
  );

  testWidgets(
    'a restored draft does not show a signature made for other lines',
    (WidgetTester tester) async {
      final String key = await _openSavedSignature(
        tester,
        visitId: 'v-restored',
        signature: _signature(lines: 'Soap:1:100'),
      );

      expect(find.text(_changed), findsOneWidget);
      expect(find.text(_unsigned), findsOneWidget);
      expect(_saved(key)['signed'], isFalse);
      await _close(tester);
    },
  );

  testWidgets(
    'a signature saved by an older build keeps its signature on open and '
    'loses it when the order changes after that',
    (WidgetTester tester) async {
      final String key = await _openSavedSignature(
        tester,
        visitId: 'v-no-record',
        signature: _signature(),
      );

      expect(find.text(_changed), findsNothing);
      expect(find.text(_unsigned), findsNothing);
      expect(find.text('Sign here'), findsNothing);
      expect(_saved(key)['signed'], isTrue);
      expect(_saved(key)['points'], isNotEmpty);
      expect(_saved(key)['lines'], isA<String>());

      await tester.ensureVisible(find.byIcon(Icons.add));
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();

      expect(find.text(_changed), findsOneWidget);
      expect(_saved(key)['signed'], isFalse);
      await _close(tester);
    },
  );

  for (final (String what, void Function(SignatureOrderItem) change)
      in <(String, void Function(SignatureOrderItem))>[
        (
          'the unit after a catalogue refresh',
          (SignatureOrderItem item) => item.uom = 'pcs',
        ),
        ('the quantity', (SignatureOrderItem item) => item.orderQty = 3),
        ('the price', (SignatureOrderItem item) => item.unitPrice = 1.6),
        (
          'the expiry date',
          (SignatureOrderItem item) => item.orderedExpiry = '2/12/2026',
        ),
        ('the remarks', (SignatureOrderItem item) => item.remarks = 'top shelf'),
      ]) {
    test('the signed record changes with $what', () {
      final SignatureOrderItem item = _line();
      final String signed = signedLinesRecord(<SignatureOrderItem>[item]);
      change(item);
      expect(
        signedLinesRecord(<SignatureOrderItem>[item]),
        isNot(equals(signed)),
      );
    });
  }

  test('the signed record holds each submitted field the shop agrees to', () {
    final SignatureOrderItem item = _line();
    const Set<String> signedFields = <String>{
      'name',
      'productName',
      'productId',
      'packingSize',
      'uom',
      'price',
      'qty',
      'expiry',
      'department',
      'departmentName',
      'shelfBatches',
      'remarks',
    };
    final List<dynamic> lines =
        jsonDecode(signedLinesRecord(<SignatureOrderItem>[item]))
            as List<dynamic>;
    expect(lines, hasLength(1));
    expect(
      (jsonDecode(lines.single as String) as Map<String, dynamic>).keys.toSet(),
      signedFields,
    );
    expect(
      submittedOrderLine(item).keys.toSet().difference(signedFields),
      <String>{'maxOrderQty'},
    );
  });

  test('a new order limit or price source does not ask for a new signature', () {
    final SignatureOrderItem item = _line();
    final String signed = signedLinesRecord(<SignatureOrderItem>[item]);
    item.maxOrderQty = 9;
    item.priceSource = 'catalogue';
    expect(signedLinesRecord(<SignatureOrderItem>[item]), signed);
  });

  test('a space left at the end of a remark is not sent and does not ask for '
      'a new signature', () {
    final SignatureOrderItem item = _line();
    final String signed = signedLinesRecord(<SignatureOrderItem>[item]);
    item.remarks = 'front shelf ';
    expect(signedLinesRecord(<SignatureOrderItem>[item]), signed);
    expect(submittedOrderLine(item)['remarks'], 'front shelf');
  });
}
