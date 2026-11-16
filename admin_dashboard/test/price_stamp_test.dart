import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_web_app/utils/price_stamp.dart';

void main() {
  test('a name or stock edit with the same price writes no stamp', () {
    expect(priceChanged(12.5, 12.5), isFalse);
    expect(priceStampFor(changed: priceChanged(12.5, 12.50)), isEmpty);
    expect(priceChanged(0.0, 0.0), isFalse);
    expect(priceChanged(null, null), isFalse);
  });

  test('a real price change writes the server time stamp', () {
    expect(priceChanged(12.5, 12.6), isTrue);
    expect(
      priceStampFor(changed: priceChanged(12.5, 13)).keys,
      contains('priceUpdatedAt'),
    );
  });
}
