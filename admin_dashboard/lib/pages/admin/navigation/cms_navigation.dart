import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../app/build_flags.dart';
import '../../../app/permission_policy.dart';
import '../../../services/permission_policy_service.dart';
import 'dashboard_pages.dart';

class CmsNavItem {
  const CmsNavItem({
    required this.page,
    required this.label,
    required this.icon,
    required this.title,
    required String description,
    this.basicDescription,
    this.section = '',
    this.keywords = const <String>[],
    this.factInHeader = true,
  }) : _description = description;

  final DashboardPage page;

  final String label;

  final IconData icon;

  final String title;

  final String _description;

  final String? basicDescription;

  final String section;

  final List<String> keywords;

  final bool factInHeader;

  String get key => page.key;

  CmsNavItem inSection(String title) => CmsNavItem(
    page: page,
    label: label,
    icon: icon,
    title: this.title,
    description: _description,
    basicDescription: basicDescription,
    section: title,
    keywords: keywords,
    factInHeader: factInHeader,
  );

  String get description =>
      isBasicEdition ? basicDescription ?? _description : _description;

  String get headerFact => factInHeader ? description : '';

  String get searchText =>
      '$label $title $description $section ${keywords.join(' ')}'.toLowerCase();
}

class CmsNavSection {
  const CmsNavSection(this.title, this.items);
  final String title;
  final List<CmsNavItem> items;
}

const List<CmsNavItem> _adminItems = <CmsNavItem>[
  CmsNavItem(
    page: DashboardPage.dashboard,
    label: 'Dashboard',
    icon: ScootIcons.dashboard,
    section: sectionOverview,
    title: 'Dashboard',
    description:
        'What needs attention today across orders, sales activity, visits, and forecasts.',
    keywords: <String>['home', 'kpi', 'summary', 'action centre'],
  ),
  CmsNavItem(
    page: DashboardPage.salesmanActivity,
    label: 'Salesman Tracking',
    icon: ScootIcons.map,
    section: sectionSalesActivity,
    title: 'Salesman Tracking',
    description:
        'Field activity, salesman performance, GPS sync, and visit status.',
    keywords: <String>['gps', 'map', 'location', 'live', 'performance'],
  ),
  CmsNavItem(
    page: DashboardPage.visitLogs,
    label: 'Visit Logs',
    icon: ScootIcons.visitLogs,
    section: sectionSalesActivity,
    title: 'Visit Logs',
    description:
        'Latest visits, retailers needing follow-up, and missed or overdue visits.',
    keywords: <String>['visits', 'history', 'arrival', 'follow-up'],
  ),
  CmsNavItem(
    page: DashboardPage.routePlanner,
    label: 'Route Planner',
    icon: ScootIcons.route,
    section: sectionSalesActivity,
    title: 'Route Planner',
    description:
        'Generate optimised Monday–Saturday salesman routes from retailer '
        'priority and road-aware distance when routing is available.',
    keywords: <String>['route', 'optimisation', 'estimate', 'plan', 'visit'],
  ),
  CmsNavItem(
    page: DashboardPage.notifications,
    label: 'Notifications',
    icon: ScootIcons.notifications,
    section: sectionOverview,
    title: 'Notifications',
    description:
        'Notification feed by date for arrival, order, and admin-visible alerts.',
    keywords: <String>['alerts', 'feed'],
  ),
  CmsNavItem(
    page: DashboardPage.allOrders,
    label: 'All Orders',
    icon: ScootIcons.orders,
    section: sectionOrders,
    title: 'All Orders',
    description:
        'Browse every submitted order. Open a row to view details and approve or reject (admins may also delete).',
    keywords: <String>['order approval', 'sales order', 'approve', 'reject'],
  ),
  CmsNavItem(
    page: DashboardPage.purchaseOrder,
    label: 'Purchase Orders',
    icon: ScootIcons.delivery,
    section: sectionOrders,
    title: 'Purchase Orders',
    description:
        'Purchase orders issued automatically when an order is approved, grouped per retailer by week.',
    keywords: <String>['po', 'procurement', 'supply'],
  ),
  CmsNavItem(
    page: DashboardPage.specialRequests,
    label: 'Special Requests',
    icon: ScootIcons.specialRequests,
    section: sectionOrders,
    title: 'Special Requests',
    description:
        'Approve or reject non-standard retailer requests. A supervisor decides for their team; an admin decides any request; branch managers view only.',
    keywords: <String>['exceptions', 'approval'],
  ),
  CmsNavItem(
    page: DashboardPage.reports,
    label: 'Reports',
    icon: ScootIcons.reports,
    section: sectionInsights,
    title: 'Reports',
    description:
        'Monthly analytics — order trend, top products, and top retailers.',
    keywords: <String>[
      'analytics',
      'monthly trend',
      'product report',
      'monthly summary',
    ],
  ),
  CmsNavItem(
    page: DashboardPage.prediction,
    label: 'Demand Forecast',
    icon: ScootIcons.forecast,
    section: sectionInsights,
    title: 'Demand Forecast',
    description:
        'Weekly demand forecast per product, with confidence and recommended action.',
    keywords: <String>[
      'forecast',
      'sarimax',
      'demand',
      'restock recommendations',
    ],
  ),
  CmsNavItem(
    page: DashboardPage.trustImpact,
    label: 'Trust & Impact',
    icon: ScootIcons.visitLogs,
    section: sectionInsights,
    title: 'Trust & Impact',
    description:
        'Read-only evidence, evaluated samples, and reasons the system abstained.',
    keywords: <String>['accuracy', 'impact', 'evidence', 'abstention', 'trust'],
  ),
  CmsNavItem(
    page: DashboardPage.department,
    label: 'Departments',
    icon: ScootIcons.layers,
    section: sectionCatalogue,
    title: 'Departments',
    description: 'Maintain the sales departments used across the catalogue.',
  ),
  CmsNavItem(
    page: DashboardPage.category,
    label: 'Categories',
    icon: ScootIcons.layers,
    section: sectionCatalogue,
    title: 'Categories',
    description: 'Manage the product category hierarchy.',
  ),
  CmsNavItem(
    page: DashboardPage.product,
    label: 'Products',
    icon: ScootIcons.products,
    section: sectionCatalogue,
    title: 'Products',
    description:
        'Manage the product catalogue — codes, pricing, packing, and visibility.',
  ),
  CmsNavItem(
    page: DashboardPage.retailerScoresheets,
    label: 'Score Sheets',
    icon: ScootIcons.assignment,
    section: sectionCatalogue,
    title: 'Score Sheets',
    description: 'Control which products appear for each retailer score sheet.',
  ),
  CmsNavItem(
    page: DashboardPage.accountLockouts,
    label: 'Account Lockouts',
    icon: ScootIcons.lock,
    section: sectionPeople,
    title: 'Account Lockouts',
    description: 'Review reported login locks and allow an immediate retry.',
    keywords: <String>['unlock', 'login', 'locked', 'recovery'],
  ),
  CmsNavItem(
    page: DashboardPage.users,
    label: 'Role Assignment',
    icon: ScootIcons.badge,
    section: sectionPeople,
    title: 'Role Assignment',
    description:
        'Create users, assign roles, and manage active or suspended access.',
    keywords: <String>['user management', 'roles', 'accounts'],
  ),
  CmsNavItem(
    page: DashboardPage.permissions,
    label: 'Role Permissions',
    icon: ScootIcons.shield,
    section: sectionPeople,
    title: 'Role Permissions',
    description:
        'Configure which view, create, edit and delete actions each dashboard '
        'role has per module. The same table is enforced across the system.',
    keywords: <String>['permission', 'matrix', 'access', 'authorization'],
  ),
  CmsNavItem(
    page: DashboardPage.userDirectory,
    label: 'Users',
    icon: ScootIcons.team,
    section: sectionPeople,
    title: 'Users',
    description: 'Review staff roles, contact details, and assignment links.',
  ),
  CmsNavItem(
    page: DashboardPage.branches,
    label: 'Branches',
    icon: ScootIcons.branch,
    section: sectionPeople,
    title: 'Branches',
    description: 'Manage physical branch locations.',
  ),
  CmsNavItem(
    page: DashboardPage.retailer,
    label: 'Retailers',
    icon: ScootIcons.store,
    section: sectionCatalogue,
    title: 'Retailers',
    description: 'Manage retailers and outlets.',
  ),
  CmsNavItem(
    page: DashboardPage.coordinateReview,
    label: 'Coordinate Review',
    icon: ScootIcons.locationSearching,
    section: sectionCatalogue,
    title: 'Coordinate Review',
    description:
        'Review missing, invalid, or duplicate retailer coordinates before route planning.',
    keywords: <String>['gps', 'latitude', 'longitude', 'geocode', 'map'],
  ),
  CmsNavItem(
    page: DashboardPage.importPreview,
    label: 'Import Centre',
    icon: ScootIcons.upload,
    section: sectionCatalogue,
    title: 'Import Centre',
    description:
        'Upload, preview, validate, and explicitly confirm safe batch imports.',
    keywords: <String>['csv', 'excel', 'products', 'retailers', 'forecast'],
  ),
  CmsNavItem(
    page: DashboardPage.departmentPic,
    label: 'Department PIC',
    icon: ScootIcons.assignment,
    section: sectionPeople,
    title: 'Retailer Department PIC',
    description: 'Assign a department PIC within a specific retailer.',
  ),
  CmsNavItem(
    page: DashboardPage.websiteLogo,
    label: 'Website Logo',
    icon: ScootIcons.document,
    section: sectionSettings,
    title: 'Website Logo',
    description: 'Update the public website logo.',
  ),
  CmsNavItem(
    page: DashboardPage.websiteTitle,
    label: 'Website Title',
    icon: ScootIcons.document,
    section: sectionSettings,
    title: 'Website Title',
    description: 'Update the public website title.',
  ),
  CmsNavItem(
    page: DashboardPage.websitePages,
    label: 'Website Pages',
    icon: ScootIcons.document,
    section: sectionSettings,
    title: 'Website Pages',
    description: 'Edit static website content pages.',
  ),
  CmsNavItem(
    page: DashboardPage.terms,
    label: 'Terms & Conditions',
    icon: ScootIcons.document,
    section: sectionSettings,
    title: 'Terms & Conditions',
    description: 'Maintain the terms and conditions content.',
  ),
  CmsNavItem(
    page: DashboardPage.account,
    label: 'Account',
    icon: ScootIcons.pricing,
    section: sectionSettings,
    title: 'Account',
    description: 'Your plan, renewal date and usage against the plan limits.',
    keywords: <String>['plan', 'billing', 'limits', 'usage', 'subscription'],
  ),
  CmsNavItem(
    page: DashboardPage.plans,
    label: 'Plans',
    icon: ScootIcons.pricing,
    section: sectionSettings,
    title: 'Plans',
    description: 'Compare plans and ask to change yours.',
    keywords: <String>['upgrade', 'pricing', 'change plan'],
  ),
  CmsNavItem(
    page: DashboardPage.privacyPolicy,
    label: 'Privacy Policy',
    icon: ScootIcons.privacy,
    section: sectionSettings,
    title: 'Privacy Policy',
    description: 'How Scoot Sales collects, uses and protects your data.',
    factInHeader: false,
  ),
  CmsNavItem(
    page: DashboardPage.termsConditions,
    label: 'Terms & Conditions',
    icon: ScootIcons.document,
    section: sectionSettings,
    title: 'Terms & Conditions',
    description: 'The terms for using Scoot Sales.',
    factInHeader: false,
  ),
  CmsNavItem(
    page: DashboardPage.banner,
    label: 'Home Page Banner',
    icon: ScootIcons.document,
    section: sectionSettings,
    title: 'Home Page Banner',
    description: 'Manage the home page banner.',
  ),
  CmsNavItem(
    page: DashboardPage.tax,
    label: 'Government Tax',
    icon: ScootIcons.document,
    section: sectionSettings,
    title: 'Government Tax',
    description: 'Configure government tax settings.',
  ),
  CmsNavItem(
    page: DashboardPage.systemGovernance,
    label: 'System Governance',
    icon: ScootIcons.lock,
    section: sectionDeveloper,
    title: 'System Governance',
    description:
        'Order retention and purge schedule, with additional developer controls.',
  ),
  CmsNavItem(
    page: DashboardPage.systemHealth,
    label: 'System Health',
    icon: ScootIcons.shield,
    section: sectionDeveloper,
    title: 'System Health',
    description:
        'Read-only data diagnostics — missing dates, coordinates, prices, and '
        'other gaps that make dashboards or route plans look empty.',
    keywords: <String>['diagnostics', 'data quality', 'health', 'checks'],
  ),
  CmsNavItem(
    page: DashboardPage.auditLog,
    label: 'Audit Log',
    icon: ScootIcons.history,
    section: sectionDeveloper,
    title: 'Audit Log',
    description:
        'Append-only history for route, import, catalogue, user, forecast, and system-setting changes.',
    keywords: <String>['history', 'changes', 'actor', 'governance'],
  ),
  CmsNavItem(
    page: DashboardPage.monthlyTrend,
    label: 'Monthly Trend',
    icon: ScootIcons.forecast,
    section: sectionInsights,
    title: 'Monthly Trend',
    description:
        'Weekly order trend inside the selected month, including weeks with zero orders.',
    keywords: <String>['reports', 'analytics'],
  ),
  CmsNavItem(
    page: DashboardPage.salesOrder,
    label: 'Order Approval',
    icon: ScootIcons.orders,
    section: sectionOrders,
    title: 'Order Approval',
    description: 'Browse every submitted order and act on it.',
  ),
  CmsNavItem(
    page: DashboardPage.productReport,
    label: 'Product Report',
    icon: ScootIcons.reports,
    section: sectionInsights,
    title: 'Product Report',
    description:
        'Product-focused report view for weekly quantities and trends.',
  ),
];

const List<CmsNavItem> _supervisorItems = <CmsNavItem>[
  CmsNavItem(
    page: DashboardPage.dashboard,
    label: 'Team Overview',
    icon: ScootIcons.dashboard,
    title: 'Team Overview',
    section: sectionMyTeam,
    description: 'Your team at a glance — orders, visits and activity.',
  ),
  CmsNavItem(
    page: DashboardPage.myTeam,
    label: 'My Team',
    icon: ScootIcons.team,
    title: 'My Team',
    section: sectionMyTeam,
    description: 'Your assigned salespeople and how today is going.',
    keywords: <String>[
      'my team',
      'my salesmen',
      'my salespeople',
      'team members',
      'my salesman',
    ],
  ),
  CmsNavItem(
    page: DashboardPage.teamActionCenter,
    label: 'Action Center',
    icon: ScootIcons.reports,
    title: 'Action Center',
    section: sectionMyTeam,
    description:
        'High-priority team insights, at-risk retailers and field follow-ups.',
  ),
  CmsNavItem(
    page: DashboardPage.teamAiSummary,
    label: 'Weekly Summary',
    icon: ScootIcons.reports,
    title: 'Weekly Summary',
    section: sectionMyTeam,
    description: 'Team AI outcomes, forecast accuracy and weekly risk history.',
  ),
  CmsNavItem(
    page: DashboardPage.teamOrders,
    label: 'Team Orders',
    icon: ScootIcons.orders,
    title: 'Team Orders',
    section: sectionMyTeam,
    description: 'Orders submitted by your assigned salesmen.',
  ),
  CmsNavItem(
    page: DashboardPage.teamVisits,
    label: 'Team Visit Logs',
    icon: ScootIcons.place,
    title: 'Team Visit Logs',
    section: sectionMyTeam,
    description: 'Retailer visits recorded by your team.',
  ),
  CmsNavItem(
    page: DashboardPage.teamActivity,
    label: 'Team Activity',
    icon: ScootIcons.map,
    title: 'Team Activity',
    section: sectionMyTeam,
    description: 'Latest field activity and tracking for your salesmen.',
    keywords: <String>['how to see how my salesman are doing today'],
  ),
  CmsNavItem(
    page: DashboardPage.teamForecast,
    label: 'Demand Forecast',
    icon: ScootIcons.forecast,
    title: 'Demand Forecast',
    section: sectionMyTeam,
    description: 'Weekly demand forecast (read-only).',
    keywords: <String>['how are the predictions doing'],
  ),
  CmsNavItem(
    page: DashboardPage.teamReports,
    label: 'Reports',
    icon: ScootIcons.reports,
    title: 'Reports',
    section: sectionMyTeam,
    description: 'Team scorecard and trends for your assigned salesmen.',
  ),
  CmsNavItem(
    page: DashboardPage.specialRequests,
    label: 'Special Requests',
    icon: ScootIcons.products,
    title: 'Special Requests',
    section: sectionMyTeam,
    description:
        'Review non-standard item requests from your assigned salesmen.',
  ),
  CmsNavItem(
    page: DashboardPage.retailerScoresheets,
    label: 'Score Sheets',
    icon: ScootIcons.assignment,
    title: 'Score Sheets',
    section: sectionMyTeam,
    description:
        'Pick a salesperson, open the score sheet of each of their shops. Editing needs an Admin tick.',
  ),
  CmsNavItem(
    page: DashboardPage.departmentPic,
    label: 'Department PIC',
    icon: ScootIcons.assignment,
    title: 'Retailer Department PIC',
    section: sectionMyTeam,
    description:
        'Department contacts at the shops of your team. Editing needs an Admin tick.',
  ),
  CmsNavItem(
    page: DashboardPage.routePlanner,
    label: 'Team Route Planner',
    icon: ScootIcons.route,
    title: 'Team Route Planner',
    section: sectionMyTeam,
    description: 'Plan optimised weekly routes for your assigned salesmen.',
  ),
  CmsNavItem(
    page: DashboardPage.notifications,
    label: 'Notifications',
    icon: ScootIcons.notifications,
    title: 'Notifications',
    section: sectionMyTeam,
    description: 'Order and visit alerts relevant to your team.',
  ),
  CmsNavItem(
    page: DashboardPage.privacyPolicy,
    label: 'Privacy Policy',
    icon: ScootIcons.privacy,
    title: 'Privacy Policy',
    section: sectionSettings,
    description: 'How Scoot Sales collects, uses and protects your data.',
    factInHeader: false,
  ),
  CmsNavItem(
    page: DashboardPage.termsConditions,
    label: 'Terms & Conditions',
    icon: ScootIcons.document,
    title: 'Terms & Conditions',
    section: sectionSettings,
    description: 'The terms for using Scoot Sales.',
    factInHeader: false,
  ),
  CmsNavItem(
    page: DashboardPage.product,
    label: 'Products',
    icon: ScootIcons.products,
    title: 'Products',
    description: 'Products your role was given permission to manage.',
  ),
  CmsNavItem(
    page: DashboardPage.department,
    label: 'Departments',
    icon: ScootIcons.layers,
    title: 'Departments',
    description: 'Departments your role was given permission to manage.',
  ),
  CmsNavItem(
    page: DashboardPage.category,
    label: 'Categories',
    icon: ScootIcons.layers,
    title: 'Categories',
    description: 'Categories your role was given permission to manage.',
  ),
  CmsNavItem(
    page: DashboardPage.websitePages,
    label: 'Website Pages',
    icon: ScootIcons.document,
    title: 'Website Pages',
    description: 'Website content your role was given permission to manage.',
  ),
];

const List<CmsNavItem> _branchManagerItems = <CmsNavItem>[
  CmsNavItem(
    page: DashboardPage.dashboard,
    label: 'Branch Overview',
    icon: ScootIcons.dashboard,
    title: 'Branch Overview',
    section: sectionMyBranch,
    description:
        'Your branch at a glance — orders, visits, active salesmen and forecasts.',
    basicDescription:
        'Your branch at a glance — orders, visits and active salesmen.',
  ),
  CmsNavItem(
    page: DashboardPage.myTeam,
    label: 'Branch Team',
    icon: ScootIcons.team,
    title: 'Branch Team',
    section: sectionMyBranch,
    description: 'Your branch salespeople and how today is going (view only).',
  ),
  CmsNavItem(
    page: DashboardPage.userDirectory,
    label: 'View Team',
    icon: ScootIcons.team,
    title: 'View Team',
    section: sectionMyBranch,
    description: 'Salesmen and supervisors in your branch (view only).',
  ),
  CmsNavItem(
    page: DashboardPage.salesmanActivity,
    label: 'Salesman Activity',
    icon: ScootIcons.person,
    title: 'Salesman Activity',
    section: sectionMyBranch,
    description: 'Live and recent activity of your branch salesmen.',
  ),
  CmsNavItem(
    page: DashboardPage.visitLogs,
    label: 'Visit Logs',
    icon: ScootIcons.visitLogs,
    title: 'Visit Logs',
    section: sectionMyBranch,
    description: 'Visit history for your branch.',
  ),
  CmsNavItem(
    page: DashboardPage.allOrders,
    label: 'Branch Orders',
    icon: ScootIcons.orders,
    title: 'Branch Orders',
    section: sectionMyBranch,
    description:
        'Orders from your branch (view only; approvals are made by supervisors and admins).',
  ),
  CmsNavItem(
    page: DashboardPage.purchaseOrder,
    label: 'Purchase Orders',
    icon: ScootIcons.delivery,
    title: 'Purchase Orders',
    section: sectionMyBranch,
    description: 'Purchase orders issued for your branch (view only).',
  ),
  CmsNavItem(
    page: DashboardPage.prediction,
    label: 'Forecast',
    icon: ScootIcons.forecast,
    title: 'Forecast',
    section: sectionMyBranch,
    description: 'Demand forecast for your branch.',
  ),
  CmsNavItem(
    page: DashboardPage.routePlanner,
    label: 'Branch Routes (view only)',
    icon: ScootIcons.route,
    title: 'Branch Routes (view only)',
    section: sectionMyBranch,
    description: 'View weekly routes planned for branch salesmen.',
  ),
  CmsNavItem(
    page: DashboardPage.reports,
    label: 'Branch Reports',
    icon: ScootIcons.reports,
    title: 'Branch Reports',
    section: sectionMyBranch,
    description: 'Monthly analytics scoped to your branch.',
  ),
  CmsNavItem(
    page: DashboardPage.specialRequests,
    label: 'Special Requests',
    icon: ScootIcons.products,
    title: 'Special Requests',
    section: sectionMyBranch,
    description: 'Review non-standard item requests raised in your branch.',
  ),
  CmsNavItem(
    page: DashboardPage.retailerScoresheets,
    label: 'Score Sheets',
    icon: ScootIcons.assignment,
    title: 'Score Sheets',
    section: sectionMyBranch,
    description:
        'Pick a salesperson, open the score sheet of each of their shops. Editing needs an Admin tick.',
  ),
  CmsNavItem(
    page: DashboardPage.departmentPic,
    label: 'Department PIC',
    icon: ScootIcons.assignment,
    title: 'Retailer Department PIC',
    section: sectionMyBranch,
    description:
        'Department contacts at the shops of your branch. Editing needs an Admin tick.',
  ),
  CmsNavItem(
    page: DashboardPage.notifications,
    label: 'Branch Notifications',
    icon: ScootIcons.notifications,
    title: 'Branch Notifications',
    section: sectionMyBranch,
    description: 'Order and visit alerts relevant to your branch.',
  ),
  CmsNavItem(
    page: DashboardPage.privacyPolicy,
    label: 'Privacy Policy',
    icon: ScootIcons.privacy,
    title: 'Privacy Policy',
    section: sectionSettings,
    description: 'How Scoot Sales collects, uses and protects your data.',
    factInHeader: false,
  ),
  CmsNavItem(
    page: DashboardPage.termsConditions,
    label: 'Terms & Conditions',
    icon: ScootIcons.document,
    title: 'Terms & Conditions',
    section: sectionSettings,
    description: 'The terms for using Scoot Sales.',
    factInHeader: false,
  ),
  CmsNavItem(
    page: DashboardPage.product,
    label: 'Products',
    icon: ScootIcons.products,
    title: 'Products',
    description: 'Products your role was given permission to manage.',
  ),
  CmsNavItem(
    page: DashboardPage.department,
    label: 'Departments',
    icon: ScootIcons.layers,
    title: 'Departments',
    description: 'Departments your role was given permission to manage.',
  ),
  CmsNavItem(
    page: DashboardPage.category,
    label: 'Categories',
    icon: ScootIcons.layers,
    title: 'Categories',
    description: 'Categories your role was given permission to manage.',
  ),
  CmsNavItem(
    page: DashboardPage.websitePages,
    label: 'Website Pages',
    icon: ScootIcons.document,
    title: 'Website Pages',
    description: 'Website content your role was given permission to manage.',
  ),
];

Map<DashboardPage, CmsNavItem> _indexed(
  DashboardRole role,
  List<CmsNavItem> items,
) {
  final Map<DashboardPage, String> sectionOf = <DashboardPage, String>{
    for (final NavSectionSpec spec in navFor(role).sections)
      for (final DashboardPage page in spec.pages) page: spec.title,
  };
  return <DashboardPage, CmsNavItem>{
    for (final CmsNavItem item in items)
      item.page: sectionOf.containsKey(item.page)
          ? item.inSection(sectionOf[item.page]!)
          : item,
  };
}

final Map<DashboardRole, Map<DashboardPage, CmsNavItem>> _itemsByRole =
    <DashboardRole, Map<DashboardPage, CmsNavItem>>{
      DashboardRole.admin: _indexed(DashboardRole.admin, _adminItems),
      DashboardRole.developer: _indexed(DashboardRole.developer, _adminItems),
      DashboardRole.branchManager: _indexed(
        DashboardRole.branchManager,
        _branchManagerItems,
      ),
      DashboardRole.supervisor: _indexed(
        DashboardRole.supervisor,
        _supervisorItems,
      ),
    };

CmsNavItem? cmsNavItemFor(DashboardRole role, DashboardPage page) =>
    _itemsByRole[role]![page];

CmsNavItem? cmsNavItem(String key) {
  final DashboardPage? page = DashboardPage.fromKey(key);
  return page == null ? null : cmsNavItemFor(DashboardRole.admin, page);
}

List<CmsNavSection> cmsSidebarSections(String role) {
  final DashboardRole? resolved = DashboardRole.fromWire(role);
  if (resolved == null) return const <CmsNavSection>[];
  final Map<DashboardPage, CmsNavItem> items = _itemsByRole[resolved]!;
  final List<CmsNavSection> sections = <CmsNavSection>[
    for (final NavSectionSpec spec in navFor(resolved).sections)
      CmsNavSection(spec.title, <CmsNavItem>[
        for (final DashboardPage page in spec.pages) items[page]!,
      ]),
  ];
  final List<CmsNavSection> visible = _withoutHiddenPages(sections);
  return _withoutRevokedModules(visible, resolved);
}

List<CmsNavSection> _withoutHiddenPages(List<CmsNavSection> sections) {
  return <CmsNavSection>[
    for (final CmsNavSection section in sections)
      if (section.items.any(
        (CmsNavItem item) => !isPageHiddenInUserTesting(item.key),
      ))
        CmsNavSection(
          section.title,
          section.items
              .where((CmsNavItem item) => !isPageHiddenInUserTesting(item.key))
              .toList(growable: false),
        ),
  ];
}

List<CmsNavSection> _withoutRevokedModules(
  List<CmsNavSection> sections,
  DashboardRole role,
) {
  return <CmsNavSection>[
    for (final CmsNavSection section in sections)
      if (section.items.any((CmsNavItem item) => _granted(item, role)))
        CmsNavSection(
          section.title,
          section.items
              .where((CmsNavItem item) => _granted(item, role))
              .toList(growable: false),
        ),
  ];
}

bool _granted(CmsNavItem item, DashboardRole role) {
  final PermissionModule? module = PermissionModuleRegistry.forPageKey(
    item.key,
  );
  if (module == null) return true;
  final PermissionPolicyService service = PermissionPolicyService.instance;
  return service.cachedAllows(role.wire, module.id, PermissionAction.view) &&
      (!navFor(role).writeGrantPages.contains(item.page) ||
          service.cachedAllowsWrite(role.wire, module.id));
}

List<CmsNavItem> cmsSearchItems(String role) {
  return <CmsNavItem>[
    for (final CmsNavSection section in cmsSidebarSections(role))
      ...section.items,
  ];
}

String cmsBreadcrumb(CmsNavItem item) {
  if (item.section.isEmpty) return item.title;
  return '${item.section}  /  ${item.title}';
}
