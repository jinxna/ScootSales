import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/screens/order_history_screen.dart';
import 'package:fmcg_sales/services/cart_draft_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

List<Map<String, dynamic>> _items(int quantity) => <Map<String, dynamic>>[
  <String, dynamic>{'productId': 'p1', 'name': 'Soap', 'qty': quantity},
];

String _key() => CartDraftCache.keyFor(salesmanUid: 'u1', retailerId: 'r1');

void _saveDraft({
  String pendingOrderId = '',
  List<Map<String, dynamic>>? items,
}) {
  CartDraftCache.save(
    _key(),
    CartDraftSnapshot(
      salesmanUid: 'u1',
      retailerId: 'r1',
      progress: pendingOrderId.isEmpty ? 2 : 4,
      pendingOrderId: pendingOrderId,
      items: items ?? _items(7),
    ),
  );
}

void main() {
  setUpAll(installTestFirebase);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CartDraftCache.resetRuntime();
    signInTestUser('u1');
  });

  test('order again keeps a draft whose order is waiting to send', () {
    _saveDraft(pendingOrderId: 'o1');

    final ReorderDraftCase outcome = saveReorderDraft(
      salesmanUid: 'u1',
      retailerId: 'r1',
      items: _items(1),
    );

    expect(outcome, ReorderDraftCase.sentWaiting);
    final CartDraftSnapshot kept = CartDraftCache.read(_key())!;
    expect(kept.pendingOrderId, 'o1');
    expect(kept.items.single['qty'], 7);
  });

  test('replace never overwrites a draft whose order is waiting to send', () {
    _saveDraft(pendingOrderId: 'o1');

    final ReorderDraftCase outcome = saveReorderDraft(
      salesmanUid: 'u1',
      retailerId: 'r1',
      items: _items(1),
      replaceUnsent: true,
    );

    expect(outcome, ReorderDraftCase.sentWaiting);
    expect(CartDraftCache.read(_key())!.items.single['qty'], 7);
  });

  test('order again does not replace an unsent cart until asked', () {
    _saveDraft();

    final ReorderDraftCase outcome = saveReorderDraft(
      salesmanUid: 'u1',
      retailerId: 'r1',
      items: _items(1),
    );

    expect(outcome, ReorderDraftCase.unsentWithItems);
    expect(CartDraftCache.read(_key())!.items.single['qty'], 7);
  });

  test('replace overwrites an unsent cart', () {
    _saveDraft();

    final ReorderDraftCase outcome = saveReorderDraft(
      salesmanUid: 'u1',
      retailerId: 'r1',
      items: _items(1),
      replaceUnsent: true,
    );

    expect(outcome, ReorderDraftCase.free);
    expect(CartDraftCache.read(_key())!.items.single['qty'], 1);
  });

  test('an empty draft needs no question', () {
    _saveDraft(items: <Map<String, dynamic>>[]);

    final ReorderDraftCase outcome = saveReorderDraft(
      salesmanUid: 'u1',
      retailerId: 'r1',
      items: _items(1),
    );

    expect(outcome, ReorderDraftCase.free);
    expect(CartDraftCache.read(_key())!.items.single['qty'], 1);
  });

  test('order again fills a shop that has no draft', () {
    final ReorderDraftCase outcome = saveReorderDraft(
      salesmanUid: 'u1',
      retailerId: 'r1',
      items: _items(2),
    );

    final CartDraftSnapshot draft = CartDraftCache.read(_key())!;
    expect(outcome, ReorderDraftCase.free);
    expect(draft.pendingOrderId, isEmpty);
    expect(draft.items.single['qty'], 2);
  });
}
