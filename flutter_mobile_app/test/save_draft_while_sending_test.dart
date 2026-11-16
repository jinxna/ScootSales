import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/providers/auth_provider.dart';
import 'package:fmcg_sales/providers/gps_provider.dart';
import 'package:fmcg_sales/screens/order_signature_screen.dart';
import 'package:fmcg_sales/services/cart_draft_cache.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

void main() {
  testWidgets(
    'Save Draft does nothing while sending, and weak signal frees the screen with the draft kept',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      signInTestUser('u1');
      final String key = CartDraftCache.keyFor(
        salesmanUid: 'u1',
        retailerId: 'r1',
        visitId: 'v1',
      );
      await CartDraftCache.saveAndWait(
        key,
        CartDraftSnapshot(
          salesmanUid: 'u1',
          retailerId: 'r1',
          visitId: 'v1',
          progress: 4,
          signatures: <String, Map<String, dynamic>>{
            'Other': <String, dynamic>{
              'points': <Map<String, num>>[
                <String, num>{'dx': 1, 'dy': 1},
                <String, num>{'dx': 9, 'dy': 9},
              ],
              'signed': true,
              'signedAt': DateTime(2026, 11, 9).millisecondsSinceEpoch,
            },
          },
        ),
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: <ChangeNotifierProvider<ChangeNotifier>>[
            ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider()),
            ChangeNotifierProvider<GpsProvider>(create: (_) => GpsProvider()),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: OrderSignatureScreen(
                visitId: 'v1',
                cartItems: <Map<String, dynamic>>[
                  <String, dynamic>{
                    'name': 'Soap',
                    'productId': '',
                    'department': 'Other',
                    'qty': 1,
                    'price': 1.0,
                    'retailerId': 'r1',
                    'retailerName': 'Shop',
                    'visitId': 'v1',
                  },
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Submit Order'));
      await tester.pump();
      expect(find.text('Sending…'), findsOneWidget);

      CartDraftCache.clear(key);
      if (find.text('Save Draft').evaluate().isNotEmpty) {
        await tester.tap(find.text('Save Draft'));
        await tester.pump();
      }

      expect(find.text('Save Draft'), findsNothing);

      expect(CartDraftCache.read(key), isNull);

      await tester.pump(const Duration(seconds: 9));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Sending…'), findsNothing);
      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Submit Order'), findsOneWidget);
      expect(find.textContaining('was not sent'), findsOneWidget);
      expect(CartDraftCache.read(key), isNotNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    },
  );
}
