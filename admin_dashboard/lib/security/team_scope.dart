import '../models/user_profile.dart';

class TeamScope {
  const TeamScope._();

  static bool includes(UserProfile viewer, Map<String, dynamic> record) {
    if (viewer.isAdmin) return true;
    if (viewer.isSupervisor) {
      final String code = salesmanCodeOf(record);
      return code.isNotEmpty && viewer.assignedSalesmanCodes.contains(code);
    }
    if (viewer.isBranchManager) {
      return viewer.branchId.isNotEmpty &&
          _text(record, 'branchId', 'branch_id') == viewer.branchId;
    }
    return false;
  }

  static List<Map<String, dynamic>> filter(
    UserProfile viewer,
    Iterable<Map<String, dynamic>> records,
  ) {
    return records
        .where((Map<String, dynamic> record) => includes(viewer, record))
        .toList(growable: false);
  }

  static String salesmanCodeOf(Map<String, dynamic> record) {
    for (final List<String> keys in const <List<String>>[
      <String>['salesmanCode', 'salesman_code'],
      <String>['salesmanId', 'salesman_id'],
      <String>['staffId', 'employeeCode'],
    ]) {
      final String value = _text(record, keys[0], keys[1]);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static String _text(Map<String, dynamic> record, String camel, String snake) {
    final Object? camelValue = record[camel];
    if (camelValue is String) return camelValue;
    final Object? snakeValue = record[snake];
    return snakeValue is String ? snakeValue : '';
  }
}
