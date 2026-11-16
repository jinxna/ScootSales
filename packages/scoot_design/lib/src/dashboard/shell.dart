import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/colors.dart';
import '../tokens/metrics.dart';

class ScootDashboardShell extends StatelessWidget {
  const ScootDashboardShell({
    super.key,
    required this.rail,
    required this.topBar,
    required this.child,
    required this.onCommandPalette,
    this.notices = const <Widget>[],
  });

  final Widget rail;
  final Widget topBar;
  final Widget child;
  final VoidCallback onCommandPalette;
  final List<Widget> notices;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            onCommandPalette,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            onCommandPalette,
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: c.page,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              rail,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    topBar,
                    Expanded(
                      child: Padding(
                        padding: ScootSpace.dashboardMain,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            for (final Widget notice in notices) ...<Widget>[
                              notice,
                              const SizedBox(height: 12),
                            ],
                            Expanded(child: child),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
