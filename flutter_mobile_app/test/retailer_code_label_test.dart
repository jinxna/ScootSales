import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/utils/order_reference.dart';

void main() {
  test(
    'VP-04 order screens show an outlet code as Code and hide an automatic record id',
    () {
      expect(retailerCodeLabel('K-0090-01'), 'Code: K-0090-01');
      expect(retailerCodeLabel(' K-0090-01 '), 'Code: K-0090-01');
      expect(retailerCodeLabel('ret-1'), 'Code: ret-1');
      expect(retailerCodeLabel('4821'), 'Code: 4821');
      expect(retailerCodeLabel('Xk3Jf9QwLz0PaB7cD2eR'), isNull);
      expect(retailerCodeLabel(''), isNull);
      expect(retailerCodeLabel('   '), isNull);
    },
  );

  test('VP-04 an id made from the shop name is not shown as a code', () {
    expect(
      retailerCodeLabel('kedai_ah_seng', retailerName: 'Kedai Ah Seng'),
      isNull,
    );
    expect(retailerCodeLabel('mart_1x9k2ab', retailerName: '好运 Mart'), isNull);
    expect(retailerCodeLabel('retailer_1x9k2ab', retailerName: '好运'), isNull);
    expect(
      retailerCodeLabel('K-0090-01', retailerName: 'Emart Moyan'),
      'Code: K-0090-01',
    );
    expect(retailerCodeLabel('kvd-001', retailerName: 'KVD'), 'Code: kvd-001');
    expect(
      retailerCodeLabel('emart_moyan_2', retailerName: 'Emart'),
      'Code: emart_moyan_2',
    );
  });

  test('VP-04 an id cut from a long shop name is hidden, and a code that '
      'starts with retailer_ shows when the shop has a plain name', () {
    final String longName = List<String>.filled(12, 'Kedai Runcit').join(' ');
    final String cutId = '${'kedai_runcit_' * 6}ke';
    expect(cutId.length, 80);
    expect(retailerCodeLabel(cutId, retailerName: longName), isNull);
    expect(
      retailerCodeLabel('retailer_7', retailerName: 'Emart'),
      'Code: retailer_7',
    );
  });
}
