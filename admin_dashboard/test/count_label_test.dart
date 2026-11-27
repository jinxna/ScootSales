import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/count_label.dart';
import 'package:flutter_web_app/utils/person_display_name.dart';

void main() {
  test('one thing is singular, every other count is plural', () {
    expect(countLabel(1, 'stop'), '1 stop');
    expect(countLabel(0, 'stop'), '0 stops');
    expect(countLabel(2, 'stop'), '2 stops');
    expect(countLabel(11, 'draft route'), '11 draft routes');
    expect(countLabel(1, 'box', plural: 'boxes'), '1 box');
    expect(countLabel(3, 'box', plural: 'boxes'), '3 boxes');
  });

  test('a person shows a name, never an email address or a bare code', () {
    expect(personDisplayName('Jayson', 'S0011'), 'Jayson');
    expect(personDisplayName('yves@example.test', 'S0012'), 'No name set (S0012)');
    expect(personDisplayName('  ', ''), 'No name set');
    final List<Map<String, dynamic>> people = <Map<String, dynamic>>[
      <String, dynamic>{'name': 'Jayson', 'salesmanCode': 'S0011'},
      <String, dynamic>{'name': 'a@example.test', 'employeeCode': 's0002'},
    ];
    expect(personNameForCode('S0011', people), 'Jayson');
    expect(personNameForCode('S0002', people), 'No name set (S0002)');
    expect(personNameForCode('SYN002', people), 'SYN002');
  });
}
