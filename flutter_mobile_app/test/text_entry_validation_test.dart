import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/utils/remarks_validator.dart';
import 'package:fmcg_sales/utils/visit_plan_validation.dart';

String? _validate({String purpose = 'Restock', String? notes}) =>
    validateVisitPlan(
      selectedDate: DateTime(2026, 12, 1),
      selectedMarketplace: 'Store A',
      selectedPurpose: purpose,
      selectedTime: '09:00',
      existingVisits: const <PlannedVisitSlot>[],
      today: DateTime(2026, 11, 11),
      selectedNotes: notes,
    );

const String _keyboardMash = "iewry34789u82772979279uewdii93289upi['[P[]';[';[";

void main() {
  test('visit purpose and notes refuse keyboard mashing', () {
    for (final String text in <String>[
      _keyboardMash,
      'iewry34789u82772979279uewdii93289upi',
      '123456789',
      '!@#%^&*()',
      'qwe123rty456',
      'TBC',
      'aaaaaa',
    ]) {
      expect(_validate(purpose: text), isNotNull, reason: text);
      expect(_validate(notes: text), isNotNull, reason: text);
    }
  });

  test('visit purpose and notes name the character rule', () {
    expect(_validate(purpose: _keyboardMash), contains('basic punctuation'));
    expect(_validate(notes: 'Café visit'), contains('basic punctuation'));
  });

  test('visit purpose and notes accept plain entries', () {
    for (final String text in <String>[
      'Restock',
      'Collect payment for invoice #1023',
      'Promo setup (Raya) - 2/3 shelves',
      'Bincang stok baru dengan pengurus',
      'Meet Mr Lim @ 3pm re: new SKU',
      'Follow-up: previous visit on Mon, 9 Nov was not completed',
    ]) {
      expect(_validate(purpose: text), isNull, reason: text);
      expect(_validate(notes: text), isNull, reason: text);
    }
    expect(
      _validate(notes: List<String>.filled(40, 'Check stock').join(' ')),
      isNull,
    );
  });

  test('order remarks refuse text with too few vowels again', () {
    expect(RemarksValidator.validate('RM 500 PCS TBC'), isNotNull);
    expect(RemarksValidator.validate('Deliver before 5pm please'), isNull);
    expect(RemarksValidator.validate('x' * 201), isNotNull);
  });
}
