import 'dart:async';

import 'package:flutter/material.dart';

import 'app/idle_timeout.dart';
import 'pages/admin/admin_web_router_page.dart';
import 'services/auth_service.dart';
import 'services/dashboard_access_session.dart';
import 'theme/dso_theme.dart';
import 'theme/theme_controller.dart';
import 'app/company_features.dart';

class DigitalSalesOrderAdminWebApp extends StatefulWidget {
  const DigitalSalesOrderAdminWebApp({super.key});

  @override
  State<DigitalSalesOrderAdminWebApp> createState() =>
      _DigitalSalesOrderAdminWebAppState();
}

class _DigitalSalesOrderAdminWebAppState
    extends State<DigitalSalesOrderAdminWebApp> {
  final DashboardAccessSession _session = DashboardAccessSession();

  @override
  void initState() {
    super.initState();
    _session.start();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _session,
      builder: (BuildContext context, Widget? _) => ValueListenableBuilder<DsoAppearance>(
        valueListenable: DsoThemeController.instance,
        builder: (BuildContext context, DsoAppearance appearance, Widget? _) {
          return MaterialApp(
            key: ValueKey<int>(_session.revision),
            title: productTitle,
            debugShowCheckedModeBanner: false,
            theme: DsoTheme.build(appearance),
            home: IdleTimeout(
              onTimeout: () => unawaited(AuthService.instance.signOut()),
              child: AdminWebRouterPage(session: _session),
            ),
          );
        },
      ),
    );
  }
}
