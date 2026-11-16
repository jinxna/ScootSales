import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/metrics.dart';

class ScootPageHeader extends StatelessWidget {
  const ScootPageHeader({
    super.key,
    required this.title,
    this.fact,
    this.actions = const <Widget>[],
  });

  final String title;
  final String? fact;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: <Widget>[
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Semantics(
              container: true,
              identifier: 'page-title',
              child: Semantics(
                container: true,
                header: true,
                label: title,
                excludeSemantics: true,
                child: Text(title, style: ScootType.h1.copyWith(color: c.ink)),
              ),
            ),
            if (fact != null) ...<Widget>[
              const SizedBox(height: 4),
              Semantics(
                container: true,
                child: Text(
                  fact!,
                  style: ScootType.body.copyWith(color: c.muted),
                ),
              ),
            ],
          ],
        ),
        if (actions.isNotEmpty)
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: actions,
          ),
      ],
    );
  }
}

class ScootCard extends StatelessWidget {
  const ScootCard({
    super.key,
    required this.child,
    this.title,
    this.trailing,
    this.padding = ScootSpace.cardBody,
    this.fill = false,
  });

  final Widget child;
  final String? title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final Widget body = Padding(padding: padding, child: child);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.line),
        borderRadius: ScootRadius.cardAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        children: <Widget>[
          if (title != null)
            Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.hair)),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        title!,
                        style: ScootType.cardTitle.copyWith(color: c.ink),
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          if (fill) Expanded(child: body) else body,
        ],
      ),
    );
  }
}
