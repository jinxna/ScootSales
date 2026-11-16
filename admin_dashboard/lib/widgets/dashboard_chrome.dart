import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../app/workspace_runtime.dart';
import '../models/user_profile.dart';
import '../pages/admin/navigation/cms_navigation.dart';
import '../pages/admin/navigation/dashboard_pages.dart';
import '../pages/help/faq_page.dart';
import '../voice/copilot/copilot_panel.dart';
import '../voice/copilot/copilot_status.dart';
import '../voice/copilot/copilot_trigger.dart';
import 'beta_badge.dart';
import 'settings_dialog.dart';

const double kDashboardCompactWidth = 900;
const double _copilotMinContentWidth = 320;
const double _shortViewportHeight = 600;
const double _shortViewportCanvasHeight = 840;

const Set<String> _collapsibleSections = <String>{
  sectionCatalogue,
  sectionPeople,
  sectionSettings,
  sectionDeveloper,
};

List<ScootNavGroup> scootNavGroups(
  List<CmsNavSection> sections, {
  String? badgeKey,
  int badgeCount = 0,
  String badgeLabel = 'waiting',
}) {
  return <ScootNavGroup>[
    for (final CmsNavSection section in sections)
      ScootNavGroup(
        label: section.title,
        collapsible:
            _collapsibleSections.contains(section.title) &&
            section.items.length > 1,
        items: <ScootNavItem>[
          for (final CmsNavItem item in section.items)
            ScootNavItem(
              id: item.key,
              label: item.label,
              icon: item.icon,
              count: item.key == badgeKey ? badgeCount : null,
              countLabel: '$badgeCount $badgeLabel',
            ),
        ],
      ),
  ];
}

class DashboardChrome extends StatefulWidget {
  const DashboardChrome({
    super.key,
    required this.user,
    required this.groups,
    required this.selectedId,
    required this.onSelect,
    required this.scopeLabel,
    required this.onSearch,
    required this.copilotStatus,
    required this.copilotOpen,
    required this.onCopilot,
    required this.onSignOut,
    required this.pageTitle,
    required this.pageFact,
    required this.child,
    this.untitledPageName = '',
    this.copilotPanelBuilder,
    this.showBeta = false,
    this.notices = const <Widget>[],
  });

  final UserProfile user;
  final List<ScootNavGroup> groups;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final String scopeLabel;
  final VoidCallback onSearch;
  final ValueListenable<CopilotServerState> copilotStatus;
  final bool copilotOpen;
  final VoidCallback onCopilot;
  final VoidCallback onSignOut;
  final String pageTitle;
  final String pageFact;
  final Widget child;
  final String untitledPageName;
  final Widget Function(bool fill)? copilotPanelBuilder;
  final bool showBeta;
  final List<Widget> notices;

  @override
  State<DashboardChrome> createState() => _DashboardChromeState();
}

class _DashboardChromeState extends State<DashboardChrome> {
  final GlobalKey _contentKey = GlobalKey(debugLabel: 'dashboardContent');

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < kDashboardCompactWidth;
        final double afterRail =
            constraints.maxWidth - (compact ? 0 : ScootSize.rail);
        final bool covers =
            widget.copilotOpen &&
            afterRail < kCopilotPanelWidth + _copilotMinContentWidth;
        final bool pushes = widget.copilotOpen && !covers;
        final Widget content = ExcludeFocus(
          key: _contentKey,
          excluding: covers,
          child: ExcludeSemantics(
            excluding: covers,
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              child: Padding(
                padding: EdgeInsets.only(
                  right: pushes ? kCopilotPanelWidth : 0,
                ),
                child: _Page(
                  title: widget.pageTitle,
                  untitledPageName: widget.untitledPageName,
                  fact: widget.pageFact,
                  showBeta: widget.showBeta,
                  notices: widget.notices,
                  compact: compact,
                  child: widget.child,
                ),
              ),
            ),
          ),
        );
        final Widget? panel =
            widget.copilotOpen && widget.copilotPanelBuilder != null
            ? widget.copilotPanelBuilder!(covers)
            : null;
        final Widget bar = Semantics(
          container: true,
          explicitChildNodes: true,
          child: _TopBar(
            user: widget.user,
            scopeLabel: widget.scopeLabel,
            onSearch: widget.onSearch,
            copilotStatus: widget.copilotStatus,
            copilotOpen: widget.copilotOpen,
            onCopilot: widget.onCopilot,
            onSignOut: widget.onSignOut,
            compact: compact,
          ),
        );
        if (compact) {
          return _CompactChrome(
            rail: _rail(context, closeDrawer: true),
            topBar: bar,
            content: content,
            panel: panel,
            onSearch: widget.onSearch,
          );
        }
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: ScootDashboardShell(
                rail: _rail(context),
                topBar: bar,
                onCommandPalette: widget.onSearch,
                child: content,
              ),
            ),
            if (panel != null)
              Positioned(
                top: ScootSize.topBar,
                bottom: 0,
                right: 0,
                left: covers ? ScootSize.rail : null,
                child: panel,
              ),
          ],
        );
      },
    );
  }

  Widget _rail(BuildContext context, {bool closeDrawer = false}) {
    return ScootRail(
      groups: widget.groups,
      selectedId: widget.selectedId,
      onSelect: (String id) {
        if (closeDrawer) Navigator.of(context).maybePop();
        widget.onSelect(id);
      },
      companyName: WorkspaceRuntime.current?.legalName,
    );
  }
}

class _CompactChrome extends StatelessWidget {
  const _CompactChrome({
    required this.rail,
    required this.topBar,
    required this.content,
    required this.panel,
    required this.onSearch,
  });

  final Widget rail;
  final Widget topBar;
  final Widget content;
  final Widget? panel;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Scaffold(
      backgroundColor: c.page,
      drawer: Drawer(width: ScootSize.rail, child: rail),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                topBar,
                Expanded(child: content),
              ],
            ),
          ),
          if (panel != null)
            Positioned(
              top: ScootSize.topBar,
              bottom: 0,
              left: 0,
              right: 0,
              child: panel!,
            ),
        ],
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({
    required this.title,
    required this.untitledPageName,
    required this.fact,
    required this.showBeta,
    required this.notices,
    required this.compact,
    required this.child,
  });

  final String title;
  final String untitledPageName;
  final String fact;
  final bool showBeta;
  final List<Widget> notices;
  final bool compact;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool scrolls = constraints.maxHeight < _shortViewportHeight;
        final Widget body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (title.isEmpty && untitledPageName.isNotEmpty)
              Semantics(
                container: true,
                identifier: 'page-title',
                child: Semantics(
                  container: true,
                  header: true,
                  label: untitledPageName,
                  excludeSemantics: true,
                  child: const SizedBox(width: double.infinity, height: 1),
                ),
              ),
            if (title.isNotEmpty) ...<Widget>[
              ScootPageHeader(
                title: title,
                fact: fact,
                actions: <Widget>[if (showBeta) const BetaBadge()],
              ),
              const SizedBox(height: ScootSpace.blockGap),
            ],
            for (final Widget notice in notices) ...<Widget>[
              notice,
              const SizedBox(height: ScootSpace.md),
            ],
            Expanded(child: child),
          ],
        );
        final Widget padded = Padding(
          padding: compact
              ? const EdgeInsets.fromLTRB(16, 16, 16, 18)
              : EdgeInsets.zero,
          child: body,
        );
        return SingleChildScrollView(
          primary: false,
          physics: scrolls ? null : const NeverScrollableScrollPhysics(),
          child: SizedBox(
            height: scrolls
                ? _shortViewportCanvasHeight
                : constraints.maxHeight,
            child: padded,
          ),
        );
      },
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.user,
    required this.scopeLabel,
    required this.onSearch,
    required this.copilotStatus,
    required this.copilotOpen,
    required this.onCopilot,
    required this.onSignOut,
    required this.compact,
  });

  final UserProfile user;
  final String scopeLabel;
  final VoidCallback onSearch;
  final ValueListenable<CopilotServerState> copilotStatus;
  final bool copilotOpen;
  final VoidCallback onCopilot;
  final VoidCallback onSignOut;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final double width = MediaQuery.sizeOf(context).width;
    return Container(
      height: ScootSize.topBar,
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 24),
      decoration: BoxDecoration(
        color: c.card,
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: <Widget>[
          if (compact)
            Builder(
              builder: (BuildContext barContext) => IconButton(
                tooltip: 'Open menu',
                onPressed: () => Scaffold.of(barContext).openDrawer(),
                icon: const Icon(ScootIcons.more),
              ),
            ),
          if (compact)
            IconButton(
              tooltip: 'Search',
              onPressed: onSearch,
              icon: const Icon(ScootIcons.search),
            )
          else
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: ScootSize.searchMaxWidth,
                  ),
                  child: ScootSearchField(
                    hint: 'Jump to a page',
                    onTap: onSearch,
                  ),
                ),
              ),
            ),
          if (compact) const Spacer(),
          if (!compact &&
              scopeLabel.trim().isNotEmpty &&
              width >= 1100) ...<Widget>[
            ScootScopePill(label: scopeLabel.trim()),
            const SizedBox(width: 10),
          ],
          CopilotTrigger(
            onPressed: onCopilot,
            status: copilotStatus,
            compact: width < 1100,
            open: copilotOpen,
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Help and questions',
            onPressed: () => showFaq(context, user),
            icon: const Icon(ScootIcons.help),
          ),
          const SizedBox(width: 6),
          ScootAccountButton(
            account: ScootAccount(
              name: user.name.trim().isEmpty
                  ? 'Current user'
                  : user.name.trim(),
              subtitle: _subtitle(),
            ),
            actions: <ScootMenuAction>[
              ScootMenuAction(
                label: 'Settings',
                icon: ScootIcons.settings,
                onSelected: () => _openSettings(context, 0),
              ),
              ScootMenuAction(
                label: 'Appearance',
                icon: ScootIcons.layers,
                onSelected: () => _openSettings(context, 1),
              ),
              ScootMenuAction(
                label: 'Help and questions',
                icon: ScootIcons.help,
                onSelected: () => showFaq(context, user),
              ),
              ScootMenuAction(
                label: 'Sign out',
                icon: ScootIcons.signOut,
                onSelected: onSignOut,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _subtitle() {
    final String branch = user.branchId.trim();
    return branch.isEmpty ? user.roleLabel : '${user.roleLabel} · $branch';
  }

  void _openSettings(BuildContext context, int tab) {
    showDsoSettings(
      context,
      initialTab: tab,
      profile: DsoSettingsProfile(
        authUid: user.uid ?? '',
        userDocId: user.docId,
        name: user.name,
        email: user.email,
        role: user.roleLabel,
        branch: user.branchId,
        userCode: user.employeeCode,
        status: user.status,
      ),
    );
  }
}
