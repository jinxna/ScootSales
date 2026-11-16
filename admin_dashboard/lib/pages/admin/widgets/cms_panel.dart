import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:scoot_design/scoot_design.dart';

class CmsPanel extends StatelessWidget {
  const CmsPanel({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.padding,
    this.headerPadding,
    this.expandBody = true,
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? headerPadding;
  final bool expandBody;

  static const double _minTitleWidth = 96;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: ScootRadius.cardAll,
        border: Border.all(color: c.line),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool canExpand = expandBody && constraints.hasBoundedHeight;
          final EdgeInsetsGeometry resolvedHeaderPadding =
              headerPadding ?? ScootSpace.cardHeader;
          final double trailingMaxWidth = math.max(
            0,
            constraints.maxWidth -
                resolvedHeaderPadding.horizontal -
                _minTitleWidth,
          );
          return Column(
            mainAxisSize: canExpand ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: resolvedHeaderPadding,
                child: constraints.maxWidth < 440 && trailing != null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Semantics(
                            container: true,
                            header: true,
                            label: title,
                            excludeSemantics: true,
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ScootType.cardTitle.copyWith(color: c.ink),
                            ),
                          ),
                          const SizedBox(height: 8),
                          trailing!,
                        ],
                      )
                    : Row(
                        children: <Widget>[
                          Expanded(
                            child: Semantics(
                              container: true,
                              header: true,
                              label: title,
                              excludeSemantics: true,
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ScootType.cardTitle.copyWith(
                                  color: c.ink,
                                ),
                              ),
                            ),
                          ),
                          if (trailing != null)
                            if (trailing is Wrap)
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: trailingMaxWidth,
                                ),
                                child: trailing!,
                              )
                            else
                              trailing!,
                        ],
                      ),
              ),
              Divider(height: 1, color: c.hair),
              if (canExpand)
                Expanded(
                  child: Padding(
                    padding: padding ?? EdgeInsets.zero,
                    child: child,
                  ),
                )
              else
                Padding(padding: padding ?? EdgeInsets.zero, child: child),
            ],
          );
        },
      ),
    );
  }
}
