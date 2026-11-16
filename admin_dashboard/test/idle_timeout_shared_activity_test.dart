import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/app/idle_timeout.dart';
import 'package:flutter_web_app/services/forecast_snapshot_storage.dart';

class _SharedTabStorage implements ForecastSnapshotStorage {
  final Map<String, String> values = <String, String>{};

  @override
  String? read(String key) => values[key];

  @override
  void remove(String key) => values.remove(key);

  @override
  void write(String key, String value) => values[key] = value;

  @override
  Iterable<String> keys() => values.keys;
}

class _SignedInUser implements User {
  @override
  String get uid => 'admin-1';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('an idle tab stays signed in while another tab is busy', (
    WidgetTester tester,
  ) async {
    final _SharedTabStorage storage = _SharedTabStorage();
    final StreamController<User?> auth = StreamController<User?>();
    int timeouts = 0;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: IdleTimeout(
            timeout: const Duration(milliseconds: 600),
            authStateChanges: auth.stream,
            storage: storage,
            onTimeout: () => timeouts++,
            child: const SizedBox.shrink(),
          ),
        ),
      );
      auth.add(_SignedInUser());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (int i = 0; i < 14; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        storage.write(
          kAdminLastActivityStorageKey,
          DateTime.now().millisecondsSinceEpoch.toString(),
        );
        expect(timeouts, 0);
      }
      final Stopwatch waited = Stopwatch()..start();
      while (timeouts == 0 && waited.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(timeouts, 1);
      await auth.close();
    });
  });
}
