import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/repositories/user_management_repository.dart';

void main() {
  test('removing a team code removes every stored spelling of it and no other code', () {
    expect(
      teamCodeSpellings(<Object?>['s001', 'S002', ' S001 ', 'SYN001', 7, null], 'S001'),
      <Object>['S001', 's001', ' S001 '],
    );
  });

  test('a code that is not stored, or a missing list, still removes the code as given', () {
    expect(teamCodeSpellings(null, 'Salesman1'), <Object>['Salesman1']);
    expect(teamCodeSpellings(<Object?>['S002'], 'S001'), <Object>['S001']);
    expect(teamCodeSpellings('S001', 'S001'), <Object>['S001']);
  });
}
