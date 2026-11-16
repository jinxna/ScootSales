import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/security/order_authorization.dart';

void main() {
  const UserProfile supervisor = UserProfile(
    docId: 'supervisor-1',
    uid: 'supervisor-1',
    email: 'supervisor@example.test',
    name: 'Supervisor',
    role: UserProfile.roleSupervisor,
    employeeCode: 'SUP-1',
    status: UserProfile.statusActive,
    assignedSalesmanCodes: <String>['S001'],
  );

  test('only submitted orders can be decided once', () {
    expect(
      OrderAuthorization.canDecideOrder(supervisor, <String, dynamic>{
        'salesmanCode': 'S001',
        'status': 'submitted',
      }),
      isTrue,
    );
    expect(
      OrderAuthorization.canDecideOrder(supervisor, <String, dynamic>{
        'salesmanCode': 'S001',
        'status': 'approved',
      }),
      isFalse,
    );
    expect(
      OrderAuthorization.canDecideOrder(supervisor, <String, dynamic>{
        'salesmanCode': 'S001',
        'status': 'Submitted',
      }),
      isFalse,
    );
    expect(
      OrderAuthorization.canDecideOrder(supervisor, <String, dynamic>{
        'salesmanCode': 'S001',
        'submissionStatus': 'submitted',
      }),
      isFalse,
    );
    expect(
      () => OrderAuthorization.ensureCanDecideOrder(
        supervisor,
        <String, dynamic>{'salesmanCode': 'S001', 'status': 'rejected'},
        action: OrderWriteAction.approve,
      ),
      throwsA(isA<OrderDecisionConflictException>()),
    );
  });

  test('an order held for review can be decided like a submitted one', () {
    final Map<String, dynamic> held = <String, dynamic>{
      'salesmanCode': 'S001',
      'status': 'held_for_review',
    };
    expect(OrderAuthorization.canDecideOrder(supervisor, held), isTrue);
    OrderAuthorization.ensureCanDecideOrder(
      supervisor,
      held,
      action: OrderWriteAction.reject,
    );
  });

  test('an admin deletes only a draft order, as the rules allow', () {
    const UserProfile admin = UserProfile(
      docId: 'admin-1',
      uid: 'admin-1',
      email: 'admin@example.test',
      name: 'Admin',
      role: UserProfile.roleAdmin,
      employeeCode: 'A0001',
      status: UserProfile.statusActive,
    );
    const UserProfile developer = UserProfile(
      docId: 'dev-1',
      uid: 'dev-1',
      email: 'dev@example.test',
      name: 'Developer',
      role: UserProfile.roleDeveloper,
      employeeCode: 'D0001',
      status: UserProfile.statusActive,
    );
    const Map<String, dynamic> submitted = <String, dynamic>{
      'status': 'submitted',
    };
    const Map<String, dynamic> draft = <String, dynamic>{'status': 'draft'};

    expect(OrderAuthorization.canDeleteOrder(admin, order: draft), isTrue);
    expect(OrderAuthorization.canDeleteOrder(admin, order: submitted), isFalse);
    expect(
      () => OrderAuthorization.ensureCanDeleteOrder(admin, order: submitted),
      throwsA(isA<StateError>()),
    );
    expect(
      OrderAuthorization.canDeleteOrder(developer, order: submitted),
      isTrue,
    );
  });

  test('incomplete submitted orders can be rejected but not approved', () {
    final Map<String, dynamic> incomplete = <String, dynamic>{
      'salesmanCode': 'S001',
      'status': 'submitted',
      'retailerId': 'R001',
      'items': <Object?>[],
      'totalBoxes': 0,
      'totalPrice': 0,
    };

    expect(OrderAuthorization.canDecideOrder(supervisor, incomplete), isTrue);
    expect(OrderAuthorization.canApproveOrder(supervisor, incomplete), isFalse);
    expect(
      () => OrderAuthorization.ensureCanDecideOrder(
        supervisor,
        incomplete,
        action: OrderWriteAction.approve,
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('incomplete'),
        ),
      ),
    );
    expect(
      () => OrderAuthorization.ensureCanDecideOrder(
        supervisor,
        incomplete,
        action: OrderWriteAction.reject,
      ),
      returnsNormally,
    );
  });
}
