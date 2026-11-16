import '../models/user_profile.dart';
import '../utils/order_data_utils.dart';
import 'team_scope.dart';

enum OrderWriteAction { approve, reject }

class OrderDecisionConflictException implements Exception {
  const OrderDecisionConflictException([
    this.message =
        'This order has already been decided. Refresh the order and try again.',
  ]);

  final String message;

  @override
  String toString() => message;
}

class OrderAuthorization {
  const OrderAuthorization._();

  static bool canManageOrder(UserProfile user, Map<String, dynamic> order) {
    if (!user.isActive) return false;
    if (user.isAdmin) return true;

    if (user.isSupervisor) return TeamScope.includes(user, order);

    return false;
  }

  static bool canDeleteOrder(UserProfile user, {Map<String, dynamic>? order}) =>
      user.isActive &&
      user.isAdmin &&
      (order == null || user.isDeveloper || order['status'] == 'draft');

  static void ensureCanDeleteOrder(
    UserProfile user, {
    Map<String, dynamic>? order,
  }) {
    if (canDeleteOrder(user, order: order)) return;
    if (order != null && user.isActive && user.isAdmin) {
      throw StateError('Only a draft order can be deleted.');
    }
    throw StateError('You do not have permission to delete this order.');
  }

  static bool canDecideOrder(UserProfile user, Map<String, dynamic> order) {
    return canManageOrder(user, order) && _canBeDecided(order);
  }

  static bool canApproveOrder(UserProfile user, Map<String, dynamic> order) {
    return canDecideOrder(user, order) && isCompleteOrder(order);
  }

  static void ensureCanDecideOrder(
    UserProfile user,
    Map<String, dynamic> order, {
    required OrderWriteAction action,
  }) {
    if (!canManageOrder(user, order)) {
      throw StateError(
        'You do not have permission to ${action.name} this order.',
      );
    }
    if (!_canBeDecided(order)) {
      throw const OrderDecisionConflictException();
    }
    if (action == OrderWriteAction.approve) {
      final String? issue = orderCompletenessIssue(order);
      if (issue != null) {
        throw StateError('Cannot approve an incomplete order. $issue');
      }
    }
  }

  static bool _canBeDecided(Map<String, dynamic> order) =>
      _status(order) == 'submitted' || _status(order) == 'held_for_review';

  static String _status(Map<String, dynamic> order) {
    final Object? status = order['status'];
    return status is String ? status.trim() : '';
  }
}
