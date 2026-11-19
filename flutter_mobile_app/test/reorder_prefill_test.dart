import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/services/cart_draft_cache.dart';
import 'package:fmcg_sales/utils/replenishment_prefill.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

String _saveDraft(String retailerId, {required int quantity}) {
  final String key = CartDraftCache.keyFor(
    salesmanUid: 'u1',
    retailerId: retailerId,
    visitId: 'v-$retailerId',
  );
  CartDraftCache.save(
    key,
    CartDraftSnapshot(
      salesmanUid: 'u1',
      retailerId: retailerId,
      visitId: 'v-$retailerId',
      progress: 2,
      items: <Map<String, dynamic>>[
        <String, dynamic>{
          'productId': 'p2',
          'name': 'Instant Baby Oat',
          'qty': quantity,
          'maxOrderQty': 5,
        },
        <String, dynamic>{
          'productId': 'p3',
          'name': 'Milk Biscuit',
          'qty': 2,
          'maxOrderQty': 5,
        },
      ],
    ),
  );
  return key;
}

Future<void> _restartApp() async {
  await CartDraftCache.initialise(uid: 'u1');
  CartDraftCache.resetRuntime();
  ReplenishmentPrefill.clear();
  await CartDraftCache.initialise(uid: 'u1');
}

Map<String, int> _quantities(String key) => <String, int>{
  for (final Map<String, dynamic> item in CartDraftCache.read(key)!.items)
    item['productId'] as String: item['qty'] as int,
};

void main() {
  setUpAll(installTestFirebase);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CartDraftCache.resetRuntime();
    ReplenishmentPrefill.clear();
    signInTestUser('u1');
  });

  test('a suggested number is set on a product already in the draft of that '
      'shop only, and is still there after the app starts again', () async {
    final String shop = _saveDraft('r1', quantity: 1);
    final String otherShop = _saveDraft('r2', quantity: 1);

    final ReorderChoice choice = await ReplenishmentPrefill.choose(
      retailerId: 'r1',
      productId: 'p2',
      suggestedQty: 3,
    );

    expect(choice.result, ReorderChoiceResult.setInDraft);
    expect(choice.quantity, 3);
    expect(_quantities(shop), <String, int>{'p2': 3, 'p3': 2});
    expect(_quantities(otherShop), <String, int>{'p2': 1, 'p3': 2});

    await _restartApp();

    expect(_quantities(shop), <String, int>{'p2': 3, 'p3': 2});
    expect(_quantities(otherShop), <String, int>{'p2': 1, 'p3': 2});
    expect(
      await ReplenishmentPrefill.take(retailerId: 'r1', productId: 'p2'),
      isNull,
    );
  });

  test('a draft whose order was already sent keeps its quantities', () async {
    final String sent = _saveDraft('r1', quantity: 4);
    CartDraftCache.save(
      sent,
      CartDraftCache.read(sent)!.copyWith(pendingOrderId: 'o1'),
    );
    final String open = CartDraftCache.keyFor(
      salesmanUid: 'u1',
      retailerId: 'r1',
      visitId: 'v-open',
    );
    CartDraftCache.save(
      open,
      CartDraftSnapshot(
        salesmanUid: 'u1',
        retailerId: 'r1',
        visitId: 'v-open',
        progress: 2,
        items: <Map<String, dynamic>>[
          <String, dynamic>{
            'productId': 'p2',
            'name': 'Instant Baby Oat',
            'qty': 1,
            'maxOrderQty': 20,
          },
        ],
      ),
    );

    final ReorderChoice choice = await ReplenishmentPrefill.choose(
      retailerId: 'r1',
      productId: 'p2',
      suggestedQty: 12,
    );

    expect(choice.result, ReorderChoiceResult.setInDraft);
    expect(choice.quantity, 12);
    expect(_quantities(sent)['p2'], 4);
    expect(_quantities(open)['p2'], 12);

    CartDraftCache.save(open, CartDraftCache.read(open)!.copyWith(pendingOrderId: 'o2'));
    final ReorderChoice allSent = await ReplenishmentPrefill.choose(
      retailerId: 'r1',
      productId: 'p2',
      suggestedQty: 9,
    );

    expect(allSent.result, ReorderChoiceResult.waitsForAdd);
    expect(_quantities(sent)['p2'], 4);
    expect(_quantities(open)['p2'], 12);
  });

  test('a suggested number above the product limit is set to the limit', () async {
    final String shop = _saveDraft('r1', quantity: 1);

    final ReorderChoice choice = await ReplenishmentPrefill.choose(
      retailerId: 'r1',
      productId: 'p2',
      suggestedQty: 9,
    );

    expect(choice.result, ReorderChoiceResult.setInDraft);
    expect(choice.quantity, 5);
    expect(_quantities(shop), <String, int>{'p2': 5, 'p3': 2});
  });

  test('a suggested number for a product not yet in the draft waits for the '
      'product, is kept after the app starts again, and is used once', () async {
    final ReorderChoice choice = await ReplenishmentPrefill.choose(
      retailerId: 'r1',
      productId: 'p2',
      suggestedQty: 3,
    );
    expect(choice.result, ReorderChoiceResult.waitsForAdd);
    expect(choice.quantity, 3);

    await _restartApp();

    expect(
      await ReplenishmentPrefill.take(retailerId: 'r2', productId: 'p2'),
      isNull,
    );
    expect(
      await ReplenishmentPrefill.take(retailerId: 'r1', productId: 'p2'),
      3,
    );
    expect(
      await ReplenishmentPrefill.take(retailerId: 'r1', productId: 'p2'),
      isNull,
    );
  });

  test('with nobody signed in a suggested number is not kept', () async {
    signInTestUser(null);

    final ReorderChoice choice = await ReplenishmentPrefill.choose(
      retailerId: 'r1',
      productId: 'p2',
      suggestedQty: 3,
    );

    expect(choice.result, ReorderChoiceResult.notKept);
  });
}
