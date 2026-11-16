import 'package:flutter/material.dart';

import 'package:scoot_design/scoot_design.dart';

import '../../theme/dso_theme.dart';
import 'catalogue_drawer.dart';
import 'catalogue_issue_count.dart';

class CatalogueWorkspace extends StatelessWidget {
  const CatalogueWorkspace({
    super.key,
    required this.title,
    required this.toolbar,
    required this.body,
    this.subtitle,
    this.issues = const <CatalogueIssueCount>[],
    this.primaryAction,
    this.secondaryActions = const <Widget>[],
    this.bulkBar,
    this.drawer,
    this.drawerOpen = false,
    this.onCloseDrawer,
    this.viewSwitcher = const <Widget>[],
  });

  static const double dockBreakpoint = 1100;
  static const double shortViewportHeight = 600;
  static const double shortViewportBodyHeight = 420;

  final String title;
  final String? subtitle;
  final List<CatalogueIssueCount> issues;
  final Widget? primaryAction;
  final List<Widget> secondaryActions;
  final Widget toolbar;
  final Widget body;
  final Widget? bulkBar;
  final Widget? drawer;
  final bool drawerOpen;

  final VoidCallback? onCloseDrawer;
  final List<Widget> viewSwitcher;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final List<Widget> header = <Widget>[
      const SizedBox(height: 4),
      SizedBox(
        width: double.infinity,
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Semantics(
              header: true,
              label: title,
              child: subtitle == null
                  ? const SizedBox.shrink()
                  : Text(
                      subtitle!,
                      style: ScootType.body.copyWith(color: dso.muted),
                    ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                ...viewSwitcher,
                ...secondaryActions,
                if (primaryAction != null) primaryAction!,
              ],
            ),
          ],
        ),
      ),
      if (issues.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Builder(
            builder: (BuildContext context) {
              final List<CatalogueIssueCount> open = issues
                  .where((CatalogueIssueCount i) => i.count > 0 || i.active)
                  .toList();
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text(
                    open.isEmpty
                        ? 'Nothing needs attention'
                        : 'Needs attention',
                    style: ScootType.smallStrong.copyWith(color: dso.ink),
                  ),
                  ...open,
                ],
              );
            },
          ),
        ),
      const SizedBox(height: 14),
      toolbar,
      if (bulkBar != null)
        Padding(padding: const EdgeInsets.only(top: 8), child: bulkBar),
      const SizedBox(height: 8),
    ];
    final Widget main = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ...header,
          Expanded(child: body),
        ],
      ),
    );
    Widget scrollingMain({required double bodyHeight}) => CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList(delegate: SliverChildListDelegate(header)),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: bodyHeight > 0
              ? SliverToBoxAdapter(
                  child: SizedBox(height: bodyHeight, child: body),
                )
              : SliverFillRemaining(hasScrollBody: true, child: body),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final bool docked = box.maxWidth >= dockBreakpoint;
        final bool open = drawerOpen && drawer != null;
        final Widget compactMain = scrollingMain(bodyHeight: 0);
        final Widget wideMain = box.maxHeight < shortViewportHeight
            ? scrollingMain(bodyHeight: shortViewportBodyHeight)
            : main;
        if (box.maxWidth < 720) {
          return Stack(
            children: <Widget>[
              Positioned.fill(child: compactMain),
              if (open) ...<Widget>[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onCloseDrawer,
                    child: ColoredBox(color: dso.ink.withValues(alpha: 0.25)),
                  ),
                ),
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: box.maxWidth < CatalogueDrawer.width
                      ? box.maxWidth
                      : CatalogueDrawer.width,
                  child: drawer!,
                ),
              ],
            ],
          );
        }
        if (docked) {
          return Row(
            children: <Widget>[
              Expanded(child: wideMain),
              if (open) SizedBox(width: CatalogueDrawer.width, child: drawer),
            ],
          );
        }
        final double drawerWidth = box.maxWidth < CatalogueDrawer.width
            ? box.maxWidth
            : CatalogueDrawer.width;
        return Stack(
          children: <Widget>[
            Positioned.fill(child: wideMain),
            if (open) ...<Widget>[
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onCloseDrawer,
                  child: ColoredBox(color: dso.ink.withValues(alpha: 0.25)),
                ),
              ),
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: drawerWidth,
                child: drawer!,
              ),
            ],
          ],
        );
      },
    );
  }
}
