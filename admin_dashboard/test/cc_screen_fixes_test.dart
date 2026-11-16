import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_web_app/control_centre/pages/audit_page.dart';
import 'package:flutter_web_app/control_centre/pages/packages_page.dart';
import 'package:flutter_web_app/control_centre/pages/staff_page.dart';
import 'package:flutter_web_app/control_centre/staff_api_client.dart';
import 'package:flutter_web_app/control_centre/store/cc_store.dart';
import 'package:flutter_web_app/control_centre/widgets/cc_nav.dart';

final CcNav _nav = CcNav(
  go: (_) {},
  openCompany: (String id, {int tab = 0}) {},
  openInvoice: (_) {},
  openOnboarding: (_) {},
);

Future<CcStore> _store(
  WidgetTester tester,
  Size size,
  Map<String, Object?> Function(String path) answer,
) async {
  final CcStore store = CcStore(
    StaffApiClient(
      client: MockClient((http.Request request) async {
        final Map<String, Object?> body = answer(request.url.path);
        return http.Response(jsonEncode(body), body.isEmpty ? 404 : 200);
      }),
      baseUri: Uri.parse('http://localhost'),
    ),
  );
  store.profile = const StaffProfile(
    email: 'owner@scoot.test',
    role: 'owner',
    capabilities: <String>{'owner.tools'},
    home: 'inbox',
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  return store;
}

Future<void> _show(
  WidgetTester tester,
  Widget page, {
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(body: page),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Map<String, Object?> _event(String id, String action, String summary) =>
    <String, Object?>{
      'eventId': id,
      'at': '2026-11-12T02:11:00Z',
      'actor': 'ops@scoot-ops.test',
      'action': action,
      'summary': summary,
    };

Future<void> _showAudit(WidgetTester tester, List<Object?> events) async {
  final CcStore store = await _store(
    tester,
    const Size(768, 1000),
    (String path) => path.endsWith('audit-events')
        ? <String, Object?>{
            'from': '2026-11-12',
            'to': '2026-11-12',
            'events': events,
          }
        : <String, Object?>{'companies': <Object?>[]},
  );
  await _show(tester, AuditPage(store: store, nav: _nav));
}

void main() {
  testWidgets('audit log shows plain words for event keys and states', (
    WidgetTester tester,
  ) async {
    await _showAudit(tester, <Object?>[
      _event(
        'e1',
        'operation.begun',
        'admin01@scoot-ops.test started invoice.credit_note.',
      ),
      _event('e2', 'operation.finished', 'lifecycle.transition completed.'),
      _event(
        'e3',
        'lifecycle.transitioned',
        'Company moved from active to past_due.',
      ),
      _event('e4', 'invoice.credit_noted', ''),
    ]);

    expect(find.text('admin01@scoot-ops.test started credit note.'), findsOneWidget);
    expect(find.text('Status change completed.'), findsOneWidget);
    expect(find.text('Company moved from Active to Past due.'), findsOneWidget);
    expect(find.text('Invoice credit noted'), findsOneWidget);
    expect(find.textContaining('invoice.credit_note'), findsNothing);
    expect(find.textContaining('lifecycle.transition'), findsNothing);
    expect(find.textContaining('past_due'), findsNothing);
  });

  testWidgets('audit log at tablet width keeps Who reachable', (
    WidgetTester tester,
  ) async {
    await _showAudit(tester, <Object?>[
      _event('e1', 'operation.begun', 'Invoice issued.'),
    ]);

    expect(find.text('Who'), findsWidgets);
    expect(find.text('ops@scoot-ops.test'), findsOneWidget);
  });

  testWidgets('package names stay whole words at tablet width', (
    WidgetTester tester,
  ) async {
    final Map<String, int?> limits = <String, int?>{'salesmen': 5};
    final CcStore store = await _store(
      tester,
      const Size(768, 1000),
      (String path) => <String, Object?>{
        'packages': <Object?>[
          for (final String name in <String>['Standard', 'Professional'])
            <String, Object?>{
              'planId': name.toLowerCase(),
              'name': name,
              'edition': name.toLowerCase(),
              'limits': limits,
              'prices': <String, Object?>{'monthly': 300, 'yearly': 3000},
            },
        ],
      },
    );
    await _show(tester, PackagesPage(store: store, nav: _nav), textScale: 0.55);

    for (final String name in <String>['Standard', 'Professional']) {
      final RenderParagraph paragraph = tester.renderObject(find.text(name));
      expect(
        paragraph.size.width,
        greaterThanOrEqualTo(paragraph.getMinIntrinsicWidth(double.infinity)),
        reason: name,
      );
    }
  });

  testWidgets('audit search finds the words on screen and the raw keys', (
    WidgetTester tester,
  ) async {
    await _showAudit(tester, <Object?>[
      _event(
        'e1',
        'operation.begun',
        'admin01@scoot-ops.test started invoice.credit_note.',
      ),
      _event(
        'e2',
        'lifecycle.transitioned',
        'Company moved from active to past_due.',
      ),
    ]);
    const String creditRow = 'admin01@scoot-ops.test started credit note.';
    const String stateRow = 'Company moved from Active to Past due.';

    final Map<String, List<String>> expected = <String, List<String>>{
      'credit note': <String>[creditRow],
      'invoice.credit_note': <String>[creditRow],
      'past due': <String>[stateRow],
      'past_due': <String>[stateRow],
      'lifecycle.transitioned': <String>[stateRow],
      'status change': <String>[],
    };
    for (final MapEntry<String, List<String>> entry in expected.entries) {
      await tester.enterText(find.byType(TextField).first, entry.key);
      await tester.pumpAndSettle();
      for (final String row in <String>[creditRow, stateRow]) {
        expect(
          find.text(row),
          entry.value.contains(row) ? findsOneWidget : findsNothing,
          reason: 'search "${entry.key}" for "$row"',
        );
      }
    }
  });

  test('every operation key the server writes has plain words', () {
    const List<String> keys = <String>[
      'directory.put',
      'plan.put',
      'plan.retire',
      'subscription.change',
      'subscription.refresh',
      'lifecycle.transition',
      'billing_email.change',
      'invoice.extension',
      'invoice.credit_note',
      'payment.void',
      'quote.price',
      'invitation.create',
      'account.revoke',
      'account.reactivate',
      'account.role',
      'account.remove',
      'account.move',
      'account.code',
      'account.deletion_accept',
      'account.deletion_cancel',
      'account.deletion_shorten',
      'account.deletion_purge',
      'products.availability',
      'products.delete',
    ];
    final Set<String> labels = <String>{};
    for (final String key in keys) {
      final String label = operationLabel(key);
      expect(label, isNot(contains(key)), reason: key);
      expect(label, isNot(contains('.')), reason: key);
      expect(label, isNot(contains('_')), reason: key);
      expect(
        auditSummaryText('owner@x.test started $key.'),
        'owner@x.test started ${label[0].toLowerCase()}${label.substring(1)}.',
        reason: key,
      );
      expect(
        auditSummaryText('$key completed.'),
        '$label completed.',
        reason: key,
      );
      expect(labels.add(label), isTrue, reason: 'two keys share "$label"');
    }
  });

  test('a key inside an email or company name is left alone', () {
    const List<String> untouched = <String>[
      'plan.put@acme.test was invited as admin.',
      'Billing email changed to directory.put-team@acme.test.',
      'Billing email changed to team-plan.put@acme.test.',
      'Billing email changed to team.plan.put.x@acme.test.',
      'Billing email changed to ops@plan.put.',
      'Billing email changed to ops@acme-plan.put.',
      'Invoice sent to quote.price@acme.test.',
    ];
    for (final String text in untouched) {
      expect(auditSummaryText(text), text);
    }
    expect(
      auditSummaryText('plan.put@acme.test started plan.put.'),
      'plan.put@acme.test started package save.',
    );
    expect(
      auditSummaryText('ops@plan.put started plan.put.'),
      'ops@plan.put started package save.',
    );
    expect(
      auditSummaryText(
        'Billing email directory.put-team@acme.test: plan.put failed after 3 recovery attempts.',
      ),
      'Billing email directory.put-team@acme.test: package save failed after 3 recovery attempts.',
    );
  });

  testWidgets(
    'staff row buttons paint a short label and keep the full accessible name',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final CcStore store = await _store(
        tester,
        const Size(1280, 900),
        (String path) => <String, Object?>{
          'staff': <Object?>[
            <String, Object?>{
              'staffId': 's1',
              'email': 'admin01@scoot-ops.test',
              'role': 'owner',
              'status': 'active',
            },
          ],
          'domains': <Object?>[],
        },
      );
      await _show(tester, StaffPage(store: store));

      expect(find.text('Change role'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Change role for admin01@scoot-ops.test'),
        findsOneWidget,
      );
      expect(find.text('Change role for admin01@scoot-ops.test'), findsNothing);
      final SemanticsData data = tester
          .getSemantics(find.text('Change role'))
          .getSemanticsData();
      expect(data.label, 'Change role for admin01@scoot-ops.test');
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.flagsCollection.isFocused, isNot(Tristate.none));
      expect(data.flagsCollection.isEnabled, Tristate.isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      semantics.dispose();
    },
  );
}
