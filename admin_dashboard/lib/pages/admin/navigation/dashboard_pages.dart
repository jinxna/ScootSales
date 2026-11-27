import '../../../models/user_profile.dart';

enum DashboardRole {
  developer(UserProfile.roleDeveloper),
  admin(UserProfile.roleAdmin),
  branchManager(UserProfile.roleBranchManager),
  supervisor(UserProfile.roleSupervisor);

  const DashboardRole(this.wire);

  final String wire;

  static DashboardRole? fromWire(String role) {
    final String normalized = role.trim().toLowerCase();
    for (final DashboardRole value in values) {
      if (value.wire == normalized) return value;
    }
    return null;
  }

  static DashboardRole? of(UserProfile user) => fromWire(user.role);
}

enum DashboardPage {
  dashboard('dashboard'),
  notifications('notifications'),
  allOrders('all_orders'),
  salesOrder('sales_order'),
  purchaseOrder('purchase_order'),
  specialRequests('special_requests'),
  salesmanActivity('salesman_activity'),
  visitLogs('visit_logs'),
  routePlanner('route_planner'),
  reports('reports'),
  productReport('product_report'),
  monthlyTrend('monthly_trend'),
  prediction('prediction'),
  trustImpact('trust_impact'),
  product('product'),
  retailer('retailer'),
  coordinateReview('coordinate_review'),
  importPreview('import_preview'),
  department('department'),
  category('category'),
  retailerScoresheets('retailer_scoresheets'),
  userDirectory('user_directory'),
  users('users'),
  permissions('permissions'),
  branches('branches'),
  departmentPic('department_pic'),
  accountLockouts('account_lockouts'),
  account('account'),
  plans('plans'),
  privacyPolicy('privacy_policy'),
  termsConditions('terms_conditions'),
  websiteLogo('website_logo'),
  websiteTitle('website_title'),
  websitePages('website_pages'),
  terms('terms'),
  banner('banner'),
  tax('tax'),
  systemGovernance('system_governance'),
  systemHealth('system_health'),
  auditLog('audit_log'),
  myTeam('my_team'),
  teamActionCenter('team_action_center'),
  teamAiSummary('team_ai_summary'),
  teamOrders('team_orders'),
  teamVisits('team_visits'),
  teamActivity('team_activity'),
  teamForecast('team_forecast'),
  teamReports('team_reports'),
  managementActionCenter('management_action_center'),
  weeklyAiSummary('weekly_ai_summary');

  const DashboardPage(this.key);

  final String key;

  static final Map<String, DashboardPage> _byKey = <String, DashboardPage>{
    for (final DashboardPage page in values) page.key: page,
  };

  static DashboardPage? fromKey(String key) => _byKey[key];

  static const DashboardPage landing = DashboardPage.dashboard;
}

class NavSectionSpec {
  const NavSectionSpec(this.title, this.pages);

  final String title;
  final List<DashboardPage> pages;
}

class RoleNav {
  const RoleNav({
    required this.sections,
    this.deepLinks = const <DashboardPage>{},
    this.aliases = const <DashboardPage, DashboardPage>{},
    this.writeGrantPages = const <DashboardPage>{},
  });

  final List<NavSectionSpec> sections;

  final Set<DashboardPage> writeGrantPages;

  final Set<DashboardPage> deepLinks;

  final Map<DashboardPage, DashboardPage> aliases;

  Set<DashboardPage> get pages => <DashboardPage>{
    for (final NavSectionSpec section in sections) ...section.pages,
    ...deepLinks,
  };

  DashboardPage? resolve(DashboardPage page) {
    final DashboardPage target = aliases[page] ?? page;
    return pages.contains(target) ? target : null;
  }
}

const String sectionOverview = 'Overview';
const String sectionOrders = 'Orders';
const String sectionSalesActivity = 'Sales Activity';
const String sectionInsights = 'Insights';
const String sectionCatalogue = 'Catalogue';
const String sectionPeople = 'People & Access';
const String sectionSettings = 'Settings';
const String sectionDeveloper = 'Developer';
const String sectionMyTeam = 'My Team';
const String sectionMyBranch = 'My Branch';

const Set<DashboardPage> _adminDeepLinks = <DashboardPage>{
  DashboardPage.plans,
  DashboardPage.websiteLogo,
  DashboardPage.websiteTitle,
  DashboardPage.websitePages,
  DashboardPage.terms,
  DashboardPage.banner,
  DashboardPage.tax,
  DashboardPage.salesOrder,
  DashboardPage.productReport,
  DashboardPage.monthlyTrend,
};

const List<NavSectionSpec> _adminSectionsBeforeSettings = <NavSectionSpec>[
  NavSectionSpec(sectionOverview, <DashboardPage>[
    DashboardPage.dashboard,
    DashboardPage.notifications,
  ]),
  NavSectionSpec(sectionOrders, <DashboardPage>[
    DashboardPage.allOrders,
    DashboardPage.purchaseOrder,
    DashboardPage.specialRequests,
  ]),
  NavSectionSpec(sectionSalesActivity, <DashboardPage>[
    DashboardPage.salesmanActivity,
    DashboardPage.visitLogs,
    DashboardPage.routePlanner,
  ]),
  NavSectionSpec(sectionInsights, <DashboardPage>[
    DashboardPage.reports,
    DashboardPage.prediction,
    DashboardPage.trustImpact,
  ]),
  NavSectionSpec(sectionCatalogue, <DashboardPage>[
    DashboardPage.product,
    DashboardPage.retailer,
    DashboardPage.coordinateReview,
    DashboardPage.importPreview,
    DashboardPage.department,
    DashboardPage.category,
    DashboardPage.retailerScoresheets,
  ]),
  NavSectionSpec(sectionPeople, <DashboardPage>[
    DashboardPage.userDirectory,
    DashboardPage.users,
    DashboardPage.permissions,
    DashboardPage.branches,
    DashboardPage.departmentPic,
    DashboardPage.accountLockouts,
  ]),
];

const NavSectionSpec _grantedCatalogue = NavSectionSpec(
  sectionCatalogue,
  <DashboardPage>[
    DashboardPage.product,
    DashboardPage.department,
    DashboardPage.category,
    DashboardPage.websitePages,
  ],
);

const Set<DashboardPage> _writeGrantPages = <DashboardPage>{
  DashboardPage.product,
  DashboardPage.department,
  DashboardPage.category,
  DashboardPage.websitePages,
};

const Map<DashboardRole, RoleNav> kRoleNav = <DashboardRole, RoleNav>{
  DashboardRole.admin: RoleNav(
    sections: <NavSectionSpec>[
      ..._adminSectionsBeforeSettings,
      NavSectionSpec(sectionSettings, <DashboardPage>[
        DashboardPage.account,
        DashboardPage.systemGovernance,
        DashboardPage.privacyPolicy,
        DashboardPage.termsConditions,
        DashboardPage.auditLog,
      ]),
    ],
    deepLinks: _adminDeepLinks,
  ),
  DashboardRole.developer: RoleNav(
    sections: <NavSectionSpec>[
      ..._adminSectionsBeforeSettings,
      NavSectionSpec(sectionSettings, <DashboardPage>[
        DashboardPage.account,
        DashboardPage.privacyPolicy,
        DashboardPage.termsConditions,
      ]),
      NavSectionSpec(sectionDeveloper, <DashboardPage>[
        DashboardPage.systemGovernance,
        DashboardPage.systemHealth,
        DashboardPage.auditLog,
      ]),
    ],
    deepLinks: _adminDeepLinks,
  ),
  DashboardRole.branchManager: RoleNav(
    sections: <NavSectionSpec>[
      NavSectionSpec(sectionMyBranch, <DashboardPage>[
        DashboardPage.dashboard,
        DashboardPage.myTeam,
        DashboardPage.userDirectory,
        DashboardPage.salesmanActivity,
        DashboardPage.visitLogs,
        DashboardPage.allOrders,
        DashboardPage.purchaseOrder,
        DashboardPage.prediction,
        DashboardPage.routePlanner,
        DashboardPage.reports,
        DashboardPage.specialRequests,
        DashboardPage.retailerScoresheets,
        DashboardPage.departmentPic,
        DashboardPage.notifications,
      ]),
      _grantedCatalogue,
      NavSectionSpec(sectionSettings, <DashboardPage>[
        DashboardPage.privacyPolicy,
        DashboardPage.termsConditions,
      ]),
    ],
    writeGrantPages: _writeGrantPages,
  ),
  DashboardRole.supervisor: RoleNav(
    sections: <NavSectionSpec>[
      NavSectionSpec(sectionMyTeam, <DashboardPage>[
        DashboardPage.dashboard,
        DashboardPage.myTeam,
        DashboardPage.teamActionCenter,
        DashboardPage.teamAiSummary,
        DashboardPage.teamOrders,
        DashboardPage.teamVisits,
        DashboardPage.teamActivity,
        DashboardPage.teamForecast,
        DashboardPage.teamReports,
        DashboardPage.specialRequests,
        DashboardPage.routePlanner,
        DashboardPage.retailerScoresheets,
        DashboardPage.departmentPic,
        DashboardPage.notifications,
      ]),
      _grantedCatalogue,
      NavSectionSpec(sectionSettings, <DashboardPage>[
        DashboardPage.privacyPolicy,
        DashboardPage.termsConditions,
      ]),
    ],
    writeGrantPages: _writeGrantPages,
    aliases: <DashboardPage, DashboardPage>{
      DashboardPage.allOrders: DashboardPage.teamOrders,
      DashboardPage.salesOrder: DashboardPage.teamOrders,
      DashboardPage.visitLogs: DashboardPage.teamVisits,
      DashboardPage.salesmanActivity: DashboardPage.teamActivity,
      DashboardPage.prediction: DashboardPage.teamForecast,
      DashboardPage.reports: DashboardPage.teamReports,
      DashboardPage.managementActionCenter: DashboardPage.teamActionCenter,
      DashboardPage.weeklyAiSummary: DashboardPage.teamAiSummary,
    },
  ),
};

RoleNav navFor(DashboardRole role) => kRoleNav[role]!;

DashboardPage? openablePage(DashboardRole role, String key) {
  final DashboardPage? requested = DashboardPage.fromKey(key);
  return requested == null ? null : navFor(role).resolve(requested);
}

Set<String> pageKeysFor(DashboardRole role) => <String>{
  for (final DashboardPage page in navFor(role).pages) page.key,
};
