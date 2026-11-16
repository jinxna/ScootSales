import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/control_centre/pages/signin_page.dart';
import 'package:flutter_web_app/control_centre/staff_auth.dart';

class _MailDownAuth extends StaffAuth {
  @override
  Future<void> signIn(String address, String password) async {
    codeNotSent = true;
    step = StaffAuthStep.code;
    error = 'Sign-in codes cannot be sent today.';
    notifyListeners();
  }

  @override
  Future<void> cancelCode() async {
    step = StaffAuthStep.signedOut;
    error = null;
    notifyListeners();
  }
}

void main() {
  testWidgets('when the code mail fails, Back shows an empty password field', (
    WidgetTester tester,
  ) async {
    final _MailDownAuth auth = _MailDownAuth();
    await tester.pumpWidget(MaterialApp(home: SignInPage(auth: auth)));
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.test');
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'secret-pass-1',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(auth.step, StaffAuthStep.code);
    await tester.ensureVisible(find.text('Back'));
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    final TextField password = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Password'),
    );
    expect(password.controller!.text, isEmpty);
  });
}
