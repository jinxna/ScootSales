import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import 'frames.dart';

class DemoOrder {
  const DemoOrder(
    this.id,
    this.retailer,
    this.salesperson,
    this.submitted,
    this.items,
    this.total,
    this.status,
  );

  final String id;
  final String retailer;
  final String salesperson;
  final String submitted;
  final int items;
  final String total;
  final String status;
}

const List<DemoOrder> demoOrders = <DemoOrder>[
  DemoOrder(
    'ORD-WALK-SR',
    'Choice Supermarket Tabuan Jaya',
    'E2E Salesperson',
    'Today 17:23',
    0,
    'RM 0.00',
    'waiting',
  ),
  DemoOrder(
    'ORD-WALK-001',
    'Choice Supermarket Tabuan Jaya',
    'E2E Salesperson',
    'Today 16:23',
    2,
    'RM 85.25',
    'waiting',
  ),
  DemoOrder(
    'ORD-WALK-002',
    'Emart Moyan',
    'E2E Salesperson',
    'Today 13:23',
    1,
    'RM 27.03',
    'waiting',
  ),
  DemoOrder(
    'ORD-WALK-003',
    'Choice Supermarket Tabuan Jaya',
    'E2E Salesperson',
    '3 Nov 16:23',
    1,
    'RM 28.12',
    'approved',
  ),
  DemoOrder(
    'ORD-WALK-004',
    'Emart Moyan',
    'E2E Salesperson',
    '2 Nov 16:23',
    1,
    'RM 18.02',
    'rejected',
  ),
  DemoOrder(
    'ORD-WALK-005',
    'Choice Supermarket Tabuan Jaya',
    'E2E Salesperson',
    '27 Oct 16:23',
    2,
    'RM 46.14',
    'approved',
  ),
  DemoOrder(
    'ORD-WALK-006',
    'Choice Supermarket Tabuan Jaya',
    'E2E Salesperson',
    '15 Oct 16:23',
    1,
    'RM 36.04',
    'waiting',
  ),
];

void _noop() {}

void _noopId(String _) {}

const List<ScootNavGroup> adminNav = <ScootNavGroup>[
  ScootNavGroup(
    items: <ScootNavItem>[
      ScootNavItem(
        id: 'dashboard',
        label: 'Dashboard',
        icon: ScootIcons.dashboard,
      ),
      ScootNavItem(
        id: 'notifications',
        label: 'Notifications',
        icon: ScootIcons.notifications,
      ),
    ],
  ),
  ScootNavGroup(
    label: 'Orders',
    items: <ScootNavItem>[
      ScootNavItem(
        id: 'all-orders',
        label: 'All Orders',
        icon: ScootIcons.orders,
        count: 4,
        countLabel: '4 orders wait for approval',
      ),
      ScootNavItem(
        id: 'purchase-orders',
        label: 'Purchase Orders',
        icon: ScootIcons.delivery,
      ),
      ScootNavItem(
        id: 'special-requests',
        label: 'Special Requests',
        icon: ScootIcons.specialRequests,
        count: 1,
        countLabel: '1 open request',
      ),
    ],
  ),
  ScootNavGroup(
    label: 'Field work',
    items: <ScootNavItem>[
      ScootNavItem(
        id: 'tracking',
        label: 'Salesman Tracking',
        icon: ScootIcons.map,
      ),
      ScootNavItem(
        id: 'visit-logs',
        label: 'Visit Logs',
        icon: ScootIcons.visitLogs,
      ),
      ScootNavItem(
        id: 'route-planner',
        label: 'Route Planner',
        icon: ScootIcons.route,
      ),
    ],
  ),
  ScootNavGroup(
    label: 'Insights',
    items: <ScootNavItem>[
      ScootNavItem(id: 'reports', label: 'Reports', icon: ScootIcons.reports),
      ScootNavItem(
        id: 'forecast',
        label: 'Demand Forecast',
        icon: ScootIcons.forecast,
      ),
    ],
  ),
  ScootNavGroup(
    label: 'Catalogue',
    collapsible: true,
    items: <ScootNavItem>[
      ScootNavItem(
        id: 'products',
        label: 'Products',
        icon: ScootIcons.products,
      ),
      ScootNavItem(id: 'retailers', label: 'Retailers', icon: ScootIcons.store),
      ScootNavItem(
        id: 'coordinates',
        label: 'Coordinate Review',
        icon: ScootIcons.place,
      ),
      ScootNavItem(
        id: 'score-sheets',
        label: 'Score Sheets',
        icon: ScootIcons.assignment,
      ),
      ScootNavItem(
        id: 'departments',
        label: 'Departments',
        icon: ScootIcons.layers,
      ),
      ScootNavItem(
        id: 'categories',
        label: 'Categories',
        icon: ScootIcons.pricing,
      ),
      ScootNavItem(
        id: 'import',
        label: 'Import Centre',
        icon: ScootIcons.upload,
      ),
    ],
  ),
  ScootNavGroup(
    label: 'People and access',
    collapsible: true,
    items: <ScootNavItem>[
      ScootNavItem(id: 'users', label: 'Users', icon: ScootIcons.team),
      ScootNavItem(
        id: 'role-assignment',
        label: 'Role Assignment',
        icon: ScootIcons.approval,
      ),
      ScootNavItem(
        id: 'role-permissions',
        label: 'Role Permissions',
        icon: ScootIcons.shield,
      ),
      ScootNavItem(id: 'branches', label: 'Branches', icon: ScootIcons.branch),
      ScootNavItem(
        id: 'department-pic',
        label: 'Retailer Department PIC',
        icon: ScootIcons.badge,
      ),
      ScootNavItem(
        id: 'lockouts',
        label: 'Account Lockouts',
        icon: ScootIcons.lock,
      ),
    ],
  ),
  ScootNavGroup(
    label: 'Company',
    collapsible: true,
    items: <ScootNavItem>[
      ScootNavItem(
        id: 'account',
        label: 'Account and plan',
        icon: ScootIcons.settings,
      ),
      ScootNavItem(id: 'audit', label: 'Audit Log', icon: ScootIcons.history),
    ],
  ),
];

const List<ScootNavGroup> supervisorNav = <ScootNavGroup>[
  ScootNavGroup(
    label: 'Today',
    items: <ScootNavItem>[
      ScootNavItem(
        id: 'dashboard',
        label: 'Team overview',
        icon: ScootIcons.dashboard,
      ),
      ScootNavItem(
        id: 'action-center',
        label: 'Action Center',
        icon: ScootIcons.inbox,
      ),
      ScootNavItem(
        id: 'notifications',
        label: 'Notifications',
        icon: ScootIcons.notifications,
        count: 16,
        countLabel: '16 unread notifications',
      ),
    ],
  ),
  ScootNavGroup(
    label: 'Team',
    items: <ScootNavItem>[
      ScootNavItem(id: 'my-team', label: 'My team', icon: ScootIcons.team),
      ScootNavItem(
        id: 'tracking',
        label: 'Team activity',
        icon: ScootIcons.map,
      ),
      ScootNavItem(
        id: 'team-orders',
        label: 'Team orders',
        icon: ScootIcons.orders,
        count: 3,
        countLabel: '3 orders wait for approval',
      ),
      ScootNavItem(
        id: 'visit-logs',
        label: 'Team visit logs',
        icon: ScootIcons.visitLogs,
      ),
      ScootNavItem(
        id: 'special-requests',
        label: 'Special requests',
        icon: ScootIcons.specialRequests,
        count: 1,
        countLabel: '1 open request',
      ),
    ],
  ),
  ScootNavGroup(
    label: 'Plan',
    items: <ScootNavItem>[
      ScootNavItem(
        id: 'route-planner',
        label: 'Team route planner',
        icon: ScootIcons.route,
      ),
      ScootNavItem(
        id: 'forecast',
        label: 'Demand forecast',
        icon: ScootIcons.forecast,
      ),
      ScootNavItem(
        id: 'weekly-summary',
        label: 'Weekly AI summary',
        icon: ScootIcons.copilot,
      ),
      ScootNavItem(id: 'reports', label: 'Reports', icon: ScootIcons.reports),
    ],
  ),
  ScootNavGroup(
    label: 'Shops',
    items: <ScootNavItem>[
      ScootNavItem(
        id: 'score-sheets',
        label: 'Score sheets',
        icon: ScootIcons.assignment,
      ),
      ScootNavItem(
        id: 'department-pic',
        label: 'Department PIC',
        icon: ScootIcons.badge,
      ),
    ],
  ),
];

Widget adminRail(
  String selected, {
  List<ScootNavGroup> groups = adminNav,
  String companyName = 'Supermarket client',
}) {
  return ScootRail(
    groups: groups,
    selectedId: selected,
    onSelect: _noopId,
    companyName: companyName,
    footerLinks: const <ScootRailLink>[
      ScootRailLink(label: 'Privacy policy', onTap: _noop),
      ScootRailLink(label: 'Terms', onTap: _noop),
    ],
  );
}

Widget adminTopBar({
  String scope = 'All branches',
  ScootCopilotStatus copilot = ScootCopilotStatus.wakingUp,
  ScootAccount account = const ScootAccount(
    name: 'E2E Admin',
    subtitle: 'Admin · B1',
  ),
}) {
  return ScootTopBar(
    onSearch: _noop,
    scopeLabel: scope,
    copilotStatus: copilot,
    onCopilot: _noop,
    onHelp: _noop,
    account: account,
    accountActions: const <ScootMenuAction>[
      ScootMenuAction(
        label: 'Change password',
        icon: ScootIcons.password,
        onSelected: _noop,
      ),
      ScootMenuAction(
        label: 'Privacy policy',
        icon: ScootIcons.privacy,
        onSelected: _noop,
      ),
      ScootMenuAction(
        label: 'Terms',
        icon: ScootIcons.document,
        onSelected: _noop,
      ),
      ScootMenuAction(
        label: 'Sign out',
        icon: ScootIcons.signOut,
        onSelected: _noop,
      ),
    ],
  );
}

Widget _statusBadge(String status) {
  switch (status) {
    case 'approved':
      return const ScootBadge.approved();
    case 'rejected':
      return const ScootBadge.rejected();
    default:
      return const ScootBadge.waiting();
  }
}

List<ScootTableColumn<DemoOrder>> orderColumns() {
  return <ScootTableColumn<DemoOrder>>[
    ScootTableColumn<DemoOrder>(
      label: 'Order ID',
      width: 150,
      cell: (BuildContext context, DemoOrder o) =>
          Text(o.id, style: ScootType.mono),
    ),
    ScootTableColumn<DemoOrder>(
      label: 'Retailer',
      flex: 3,
      cell: (BuildContext context, DemoOrder o) => Text(o.retailer),
    ),
    ScootTableColumn<DemoOrder>(
      label: 'Salesperson',
      flex: 2,
      cell: (BuildContext context, DemoOrder o) => Text(o.salesperson),
    ),
    ScootTableColumn<DemoOrder>(
      label: 'Submitted',
      width: 130,
      cell: (BuildContext context, DemoOrder o) => Text(o.submitted),
    ),
    ScootTableColumn<DemoOrder>(
      label: 'Items',
      width: 70,
      numeric: true,
      cell: (BuildContext context, DemoOrder o) => Text('${o.items}'),
    ),
    ScootTableColumn<DemoOrder>(
      label: 'Total',
      width: 110,
      numeric: true,
      cell: (BuildContext context, DemoOrder o) =>
          Text(o.total, style: const TextStyle(fontWeight: FontWeight.w600)),
    ),
    ScootTableColumn<DemoOrder>(
      label: 'Status',
      width: 200,
      cell: (BuildContext context, DemoOrder o) => _statusBadge(o.status),
    ),
  ];
}

Widget ordersPage({
  required ScootLoadPhase phase,
  String title = 'All Orders',
  List<DemoOrder> rows = demoOrders,
  Duration stillLoadingAfter = ScootTiming.stillLoadingAfter,
  bool hasMore = true,
  bool loadingMore = false,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      ScootPageHeader(
        title: title,
        actions: <Widget>[
          OutlinedButton.icon(
            onPressed: _noop,
            icon: const Icon(ScootIcons.download, size: 18),
            label: const Text('Export CSV'),
          ),
        ],
      ),
      const SizedBox(height: ScootSpace.blockGap),
      Expanded(
        child: ScootCard(
          padding: EdgeInsets.zero,
          fill: true,
          child: ScootDataTable<DemoOrder>(
            columns: orderColumns(),
            rows: rows,
            phase: phase,
            onRetry: _noop,
            stillLoadingAfter: stillLoadingAfter,
            emptyTitle: 'No orders match these filters',
            emptyMessage: 'Clear a filter to see more orders.',
            emptyAction: const OutlinedButton(
              onPressed: _noop,
              child: Text('Clear filters'),
            ),
            hasMore: hasMore,
            loadingMore: loadingMore,
            countLabel: '${rows.length} orders',
            live: true,
            isSelected: (DemoOrder o) => o.id == 'ORD-WALK-001',
            onRowTap: (DemoOrder o) {},
            rowLabel: (DemoOrder o) =>
                '${o.id}, ${o.retailer}, ${o.total}, ${o.status}',
          ),
        ),
      ),
    ],
  );
}

Widget dashboardShell({
  required String selected,
  required Widget child,
  List<Widget> notices = const <Widget>[],
  List<ScootNavGroup> groups = adminNav,
  String companyName = 'Supermarket client',
  String scope = 'All branches',
  ScootAccount account = const ScootAccount(
    name: 'E2E Admin',
    subtitle: 'Admin · B1',
  ),
  ScootCopilotStatus copilot = ScootCopilotStatus.wakingUp,
}) {
  return ScootDashboardShell(
    rail: adminRail(selected, groups: groups, companyName: companyName),
    topBar: adminTopBar(scope: scope, account: account, copilot: copilot),
    onCommandPalette: _noop,
    notices: notices,
    child: child,
  );
}

Widget _kpi(BuildContext context, String label, String value, String note) {
  final ScootColors c = ScootColors.of(context);
  return Expanded(
    child: ScootCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: ScootType.smallStrong.copyWith(color: c.text2)),
          const SizedBox(height: 4),
          Text(value, style: ScootType.kpi.copyWith(color: c.ink)),
          Text(note, style: ScootType.small.copyWith(color: c.muted)),
        ],
      ),
    ),
  );
}

Widget statesPage(BuildContext context) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      const ScootPageHeader(
        title: 'Good evening, E2E',
        fact: 'Wednesday, 4 November 2026 · All branches',
        actions: <Widget>[
          FilledButton(onPressed: _noop, child: Text('Primary')),
          OutlinedButton(onPressed: _noop, child: Text('Secondary')),
          FilledButton(onPressed: null, child: Text('Disabled')),
        ],
      ),
      const SizedBox(height: ScootSpace.blockGap),
      Row(
        children: <Widget>[
          _kpi(context, 'Orders today', '3', 'Not counting rejected orders'),
          const SizedBox(width: 14),
          _kpi(context, 'Waiting for approval', '4', 'Oldest from 15 Oct'),
          const SizedBox(width: 14),
          _kpi(context, 'Order value today', 'RM 92.28', 'All branches'),
        ],
      ),
      const SizedBox(height: ScootSpace.blockGap),
      const Expanded(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: ScootCard(
                title: 'Loading (skeleton)',
                fill: true,
                child: ScootLoadingState(
                  onRetry: _noop,
                  skeleton: ScootSkeletonLines(
                    widthFactors: <double>[0.9, 0.7, 0.8, 0.5, 0.6],
                    lineHeight: 14,
                    gap: 16,
                  ),
                ),
              ),
            ),
            SizedBox(width: 14),
            Expanded(
              child: ScootCard(
                title: 'Still loading after 10 s',
                fill: true,
                child: ScootLoadingState(
                  onRetry: _noop,
                  stillLoadingAfter: Duration.zero,
                  skeleton: ScootSkeletonLines(
                    widthFactors: <double>[0.9, 0.7, 0.8, 0.5, 0.6],
                    lineHeight: 14,
                    gap: 16,
                  ),
                ),
              ),
            ),
            SizedBox(width: 14),
            Expanded(
              child: ScootCard(
                title: 'Empty',
                fill: true,
                child: Center(
                  child: ScootEmptyState(
                    icon: ScootIcons.noEvent,
                    title: 'No visits today',
                    message: 'Visits show here when they are logged.',
                  ),
                ),
              ),
            ),
            SizedBox(width: 14),
            Expanded(
              child: ScootCard(
                title: 'Error',
                fill: true,
                child: Center(child: ScootErrorState(onRetry: _noop)),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

Widget componentsPage(BuildContext context) {
  final ScootColors c = ScootColors.of(context);
  Widget row(String label, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 160,
            child: Text(
              label,
              style: ScootType.smallStrong.copyWith(color: c.text2),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: children,
            ),
          ),
        ],
      ),
    );
  }

  return SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const ScootPageHeader(
          title: 'Components',
          fact: 'Every dashboard building block in each state',
        ),
        const SizedBox(height: ScootSpace.blockGap),
        ScootCard(
          title: 'Status and controls',
          child: Column(
            children: <Widget>[
              row('Status badges', const <Widget>[
                ScootBadge.waiting(),
                ScootBadge.approved(),
                ScootBadge.rejected(),
                ScootBadge.attention(label: 'Past due'),
                ScootBadge.draft(),
                ScootBadge(label: 'Not verifiable'),
                ScootBadge(label: 'Needs review', tone: ScootTone.warning),
                ScootBadge(label: 'Completed', tone: ScootTone.success),
              ]),
              row('Count badges', <Widget>[
                const ScootCountBadge(count: 4, semanticLabel: '4 waiting'),
                const ScootCountBadge(count: 128, semanticLabel: '128 waiting'),
              ]),
              row('Scout button', const <Widget>[
                ScootCopilotButton(
                  status: ScootCopilotStatus.ready,
                  onPressed: _noop,
                ),
                ScootCopilotButton(
                  status: ScootCopilotStatus.wakingUp,
                  onPressed: _noop,
                ),
                ScootCopilotButton(
                  status: ScootCopilotStatus.offline,
                  onPressed: _noop,
                ),
              ]),
              row('Scope pill', const <Widget>[
                ScootScopePill(label: 'All branches'),
                ScootScopePill(label: 'Kuching HQ'),
                ScootScopePill(label: 'My team · 4 salespeople'),
              ]),
              row('Buttons', <Widget>[
                const FilledButton(onPressed: _noop, child: Text('Approve')),
                FilledButton.icon(
                  onPressed: _noop,
                  icon: const Icon(ScootIcons.add, size: 18),
                  label: const Text('New route'),
                ),
                const OutlinedButton(onPressed: _noop, child: Text('Cancel')),
                const TextButton(onPressed: _noop, child: Text('Open')),
                const FilledButton(onPressed: null, child: Text('Disabled')),
                const IconButton(
                  onPressed: _noop,
                  tooltip: 'More actions',
                  icon: Icon(ScootIcons.more),
                ),
              ]),
              row('Search', <Widget>[
                const SizedBox(
                  width: 420,
                  child: ScootSearchField(
                    hint: 'Jump to a page or order ID',
                    onTap: _noop,
                  ),
                ),
              ]),
              row('Text field', <Widget>[
                const SizedBox(
                  width: 320,
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Order ID, retailer or salesperson',
                      prefixIcon: Icon(ScootIcons.search, size: 18),
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
        const SizedBox(height: ScootSpace.blockGap),
        ScootCard(
          title: 'Notice banners',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ScootNotice.pastDue(since: '1 Nov 2026', onOpenAccount: _noop),
              const SizedBox(height: 10),
              ScootNotice.readOnly(),
              const SizedBox(height: 10),
              ScootNotice.roleChanged(
                roleName: 'Supervisor',
                pagesLabel: 'supervisor',
                onDismiss: _noop,
              ),
              const SizedBox(height: 10),
              const ScootStillLoadingBar(
                message: 'Still loading. The connection may be slow.',
                onRetry: _noop,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

final List<GalleryScene> dashboardScenes = <GalleryScene>[
  GalleryScene(
    id: 'dashboard-orders-ready',
    title: 'Dashboard · table ready, row selected, Load more',
    surface: GallerySurface.dashboard,
    builder: (BuildContext context) => dashboardShell(
      selected: 'all-orders',
      child: ordersPage(phase: ScootLoadPhase.ready),
    ),
  ),
  GalleryScene(
    id: 'dashboard-orders-loading-more',
    title: 'Dashboard · table loading the next 50',
    surface: GallerySurface.dashboard,
    builder: (BuildContext context) => dashboardShell(
      selected: 'all-orders',
      child: ordersPage(phase: ScootLoadPhase.ready, loadingMore: true),
    ),
  ),
  GalleryScene(
    id: 'dashboard-orders-loading',
    title: 'Dashboard · table skeleton in final size',
    surface: GallerySurface.dashboard,
    builder: (BuildContext context) => dashboardShell(
      selected: 'all-orders',
      child: ordersPage(phase: ScootLoadPhase.loading),
    ),
  ),
  GalleryScene(
    id: 'dashboard-orders-still-loading',
    title: 'Dashboard · Still loading after 10 s',
    surface: GallerySurface.dashboard,
    builder: (BuildContext context) => dashboardShell(
      selected: 'all-orders',
      child: ordersPage(
        phase: ScootLoadPhase.loading,
        stillLoadingAfter: Duration.zero,
      ),
    ),
  ),
  GalleryScene(
    id: 'dashboard-orders-empty',
    title: 'Dashboard · table empty',
    surface: GallerySurface.dashboard,
    builder: (BuildContext context) => dashboardShell(
      selected: 'all-orders',
      child: ordersPage(phase: ScootLoadPhase.ready, rows: const <DemoOrder>[]),
    ),
  ),
  GalleryScene(
    id: 'dashboard-orders-error',
    title: 'Dashboard · table error with Retry',
    surface: GallerySurface.dashboard,
    builder: (BuildContext context) => dashboardShell(
      selected: 'all-orders',
      child: ordersPage(phase: ScootLoadPhase.error),
    ),
  ),
  GalleryScene(
    id: 'dashboard-notices-and-states',
    title: 'Dashboard · notices, card states, buttons',
    surface: GallerySurface.dashboard,
    builder: (BuildContext context) => dashboardShell(
      selected: 'dashboard',
      notices: <Widget>[
        ScootNotice.pastDue(since: '1 Nov 2026', onOpenAccount: _noop),
        ScootNotice.roleChanged(
          roleName: 'Supervisor',
          pagesLabel: 'supervisor',
          onDismiss: _noop,
        ),
      ],
      child: const Builder(builder: statesPage),
    ),
  ),
  GalleryScene(
    id: 'dashboard-components',
    title: 'Dashboard · components',
    surface: GallerySurface.dashboard,
    height: 1100,
    builder: (BuildContext context) => dashboardShell(
      selected: 'products',
      copilot: ScootCopilotStatus.ready,
      child: const Builder(builder: componentsPage),
    ),
  ),
  GalleryScene(
    id: 'dashboard-supervisor-read-only',
    title: 'Dashboard · supervisor rail, read-only notice',
    surface: GallerySurface.dashboard,
    builder: (BuildContext context) => dashboardShell(
      selected: 'team-orders',
      groups: supervisorNav,
      companyName: 'Supervisor',
      scope: 'My team · 4 salespeople',
      account: const ScootAccount(
        name: 'E2E Supervisor',
        subtitle: 'Supervisor · B1',
      ),
      copilot: ScootCopilotStatus.offline,
      notices: <Widget>[
        ScootNotice.readOnly(message: 'Only an admin can change orders.'),
      ],
      child: ordersPage(
        phase: ScootLoadPhase.ready,
        title: 'Team orders',
        hasMore: false,
      ),
    ),
  ),
  GalleryScene(
    id: 'dashboard-account-menu',
    title: 'Dashboard · account menu open',
    surface: GallerySurface.dashboard,
    builder: (BuildContext context) => dashboardShell(
      selected: 'all-orders',
      child: ordersPage(phase: ScootLoadPhase.ready),
    ),
  ),
  GalleryScene(
    id: 'dashboard-keyboard-focus',
    title: 'Dashboard · visible keyboard focus',
    surface: GallerySurface.dashboard,
    builder: (BuildContext context) => dashboardShell(
      selected: 'all-orders',
      child: ordersPage(phase: ScootLoadPhase.ready),
    ),
  ),
  GalleryScene(
    id: 'dashboard-orders-dark',
    title: 'Dashboard · dark mode',
    surface: GallerySurface.dashboard,
    brightness: Brightness.dark,
    builder: (BuildContext context) => dashboardShell(
      selected: 'all-orders',
      notices: <Widget>[
        ScootNotice.pastDue(since: '1 Nov 2026', onOpenAccount: _noop),
      ],
      child: ordersPage(phase: ScootLoadPhase.ready),
    ),
  ),
];
