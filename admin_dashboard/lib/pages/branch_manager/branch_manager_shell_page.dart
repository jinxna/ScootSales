import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../app/role_guard.dart';
import '../../app/build_flags.dart';
import '../../app/browser_page_history.dart';
import '../../app/browser_page_history_session.dart';
import '../../app/web_page_route.dart';
import '../../app_runtime.dart';
import '../../models/user_profile.dart';
import '../../services/order_submission_alerts.dart';
import '../../services/auth_service.dart';
import '../../services/permission_policy_service.dart';
import '../admin/navigation/cms_navigation.dart';
import '../admin/navigation/dashboard_pages.dart';
import '../admin/navigation/page_not_available.dart';
import '../admin/widgets/cms_command_palette.dart';
import '../admin/views/all_orders_page.dart';
import '../admin/views/dashboard_overview_page.dart';
import '../admin/views/category_cms_page.dart';
import '../admin/views/content_pages_cms_page.dart';
import '../admin/views/department_cms_page.dart';
import '../admin/views/department_pic_page.dart';
import '../admin/views/product_cms_page.dart';
import '../admin/views/my_team_page.dart';
import '../admin/views/prediction_page.dart';
import '../admin/views/purchase_order_page.dart';
import '../admin/views/reports_hub_page.dart';
import '../admin/views/retailer_score_sheet_page.dart';
import '../admin/views/route_planner_page.dart';
import '../admin/views/salesman_activity_page.dart';
import '../admin/views/special_requests_page.dart';
import '../admin/views/user_directory_page.dart';
import '../admin/views/visit_logs_page.dart';
import '../../voice/dashboard_voice_catalog.dart';
import '../../voice/copilot/copilot_client.dart';
import '../../voice/copilot/copilot_panel.dart';
import '../../voice/copilot/copilot_status.dart';
import '../../voice/dashboard_voice_types.dart';
import '../../widgets/dashboard_chrome.dart';
import '../legal_documents_page.dart';

class BranchManagerShellPage extends StatefulWidget {
  const BranchManagerShellPage({super.key, required this.currentUser});

  final UserProfile currentUser;

  @override
  State<BranchManagerShellPage> createState() => _BranchManagerShellPageState();
}

class _BranchManagerShellPageState extends State<BranchManagerShellPage> {
  late String _selectedKey;
  void Function()? _cancelBrowserHistorySubscription;
  bool _copilotOpen = false;
  late final CopilotServerClient? _copilotServer =
      copilotServerFromEnvironment();
  late final CopilotServerStatus _copilotStatus = CopilotServerStatus(
    _copilotServer,
  );
  final GlobalKey _copilotPanelKey = GlobalKey();

  String get _sessionUid => widget.currentUser.uid ?? widget.currentUser.docId;

  @override
  void initState() {
    super.initState();
    unawaited(_copilotStatus.wake());
    PermissionPolicyService.instance.startSession(
      role: widget.currentUser.role,
    );
    PermissionPolicyService.instance.policy.addListener(_handlePolicyChanged);
    _startTeamAlerts();
    _selectedKey = sessionPageKey(_sessionUid, _canonicalKey);
    _cancelBrowserHistorySubscription = listenForBrowserPageChanges(() {
      if (!mounted) return;
      setState(() => _selectedKey = sessionPageKey(_sessionUid, _canonicalKey));
    });
  }

  final List<OrderSubmissionAlerts> _teamAlerts = <OrderSubmissionAlerts>[];

  @override
  void didUpdateWidget(covariant BranchManagerShellPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUser.branchId != widget.currentUser.branchId ||
        !listEquals(
          oldWidget.currentUser.assignedSalesmanCodes,
          widget.currentUser.assignedSalesmanCodes,
        )) {
      _stopTeamAlerts();
      _startTeamAlerts();
    }
  }

  void _stopTeamAlerts() {
    for (final OrderSubmissionAlerts alerts in _teamAlerts) {
      unawaited(alerts.dispose());
    }
    _teamAlerts.clear();
  }

  void _startTeamAlerts() {
    if (!AppRuntime.firebaseReady) return;
    for (final bool requests in const <bool>[false, true]) {
      _teamAlerts.add(
        OrderSubmissionAlerts(
          onAlert: _showTeamAlert,
          specialRequests: requests,
          informationalRequests: true,
        )..start(
          OrderSubmissionAlerts.scopedChanges(
            FirebaseFirestore.instance,
            widget.currentUser,
            specialRequests: requests,
          ),
        ),
      );
    }
  }

  void _showTeamAlert(OrderAlert alert) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(alert.message),
        action: SnackBarAction(
          label: alert.specialRequest ? 'View requests' : 'View orders',
          onPressed: () =>
              _select(alert.specialRequest ? 'special_requests' : 'all_orders'),
        ),
      ),
    );
  }

  @override
  void dispose() {
    PermissionPolicyService.instance.policy.removeListener(
      _handlePolicyChanged,
    );
    _stopTeamAlerts();
    _copilotStatus.dispose();
    _cancelBrowserHistorySubscription?.call();
    super.dispose();
  }

  void _handlePolicyChanged() {
    if (mounted) setState(() {});
  }

  String _canonicalKey(String key) =>
      RoleGuard.canonicalKey(widget.currentUser, key);

  void _select(String key) {
    final String safeKey = _canonicalKey(key);
    if (_selectedKey == safeKey) return;
    pushBrowserPageFragment(fragmentForPageKey(safeKey), uid: _sessionUid);
    setState(() => _selectedKey = safeKey);
  }

  List<DashboardVoicePage> get _copilotPages =>
      cmsSearchItems(DashboardRole.branchManager.wire)
          .map(
            (CmsNavItem item) => dashboardVoicePage(
              key: item.key,
              label: item.label,
              description: item.description,
            ),
          )
          .toList(growable: false);

  void _toggleCopilot() => setState(() => _copilotOpen = !_copilotOpen);

  DashboardPage? get _page =>
      RoleGuard.pageFor(widget.currentUser, _selectedKey);

  CmsNavItem? get _current {
    final DashboardPage? page = _page;
    return page == null
        ? null
        : cmsNavItemFor(DashboardRole.branchManager, page);
  }

  bool get _hasBranch => widget.currentUser.branchId.trim().isNotEmpty;

  void _openCommandPalette() {
    showCmsCommandPalette(
      context: context,
      items: cmsSearchItems(DashboardRole.branchManager.wire),
      currentKey: _selectedKey,
      onSelected: _select,
    );
  }

  @override
  Widget build(BuildContext context) {
    final CmsNavItem? current = _current;
    return Scaffold(
      body: DashboardChrome(
        user: widget.currentUser,
        groups: scootNavGroups(
          cmsSidebarSections(DashboardRole.branchManager.wire),
        ),
        selectedId: _page?.key,
        onSelect: _select,
        scopeLabel: _hasBranch
            ? 'Branch ${widget.currentUser.branchId}'
            : 'No branch assigned',
        onSearch: _openCommandPalette,
        copilotStatus: _copilotStatus,
        copilotOpen: _copilotOpen,
        onCopilot: _toggleCopilot,
        onSignOut: () => AuthService.instance.signOut(),
        pageTitle: current?.page == DashboardPage.dashboard
            ? ''
            : current?.title ?? pageNotAvailableTitle,
        pageFact: current?.description ?? pageNotAvailableMessage,
        untitledPageName: current?.page == DashboardPage.dashboard
            ? current?.title ?? ''
            : '',
        showBeta:
            kUserTestingMode && current != null && isBetaPageKey(current.key),
        notices: <Widget>[
          if (!_hasBranch)
            const ScootNotice(
              tone: ScootTone.warning,
              title: 'No branch assigned to you yet',
              message:
                  'Ask an admin to set your "branchId" in User Management. Until then this console withholds branch data. It never falls back to records of other branches.',
            ),
        ],
        copilotPanelBuilder: (bool fill) => CopilotPanel(
          key: _copilotPanelKey,
          fill: fill,
          currentUser: widget.currentUser,
          pages: _copilotPages,
          onPageRequested: (String key) async {
            if (mounted) _select(key);
          },
          onClose: _toggleCopilot,
          status: _copilotStatus,
          server: _copilotServer,
        ),
        child: _selectable(_buildSelectedPage()),
      ),
    );
  }

  Widget _selectable(Widget page) => _selectedKey == 'route_planner'
      ? SelectionContainer.disabled(child: page)
      : SelectionArea(child: page);

  Widget _notAvailable() => PageNotAvailable(
    requestedKey: _selectedKey,
    landingLabel: 'Branch Overview',
    onOpenLanding: () => _select(RoleGuard.landingKey),
  );

  Widget _buildSelectedPage() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (!_hasBranch) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            'Branch data is hidden until your branch is assigned.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    final DashboardPage? page = _page;
    if (page == null) return _notAvailable();
    switch (page) {
      case DashboardPage.privacyPolicy:
        return const LegalDocumentPage(
          document: LegalDocumentKind.privacyPolicy,
          embedded: true,
        );
      case DashboardPage.termsConditions:
        return const LegalDocumentPage(
          document: LegalDocumentKind.termsAndConditions,
          embedded: true,
        );
      case DashboardPage.routePlanner:
        return RoutePlannerPage(
          currentUser: widget.currentUser,
          onNavigateRequested: _select,
        );
      case DashboardPage.myTeam:
        return MyTeamPage(
          currentUser: widget.currentUser,
          onNavigate: (MyTeamDestination d, String _) => _select(switch (d) {
            MyTeamDestination.orders => DashboardPage.allOrders.key,
            MyTeamDestination.visits => DashboardPage.visitLogs.key,
            MyTeamDestination.activity || MyTeamDestination.routePlanner =>
              DashboardPage.salesmanActivity.key,
          }),
        );
      case DashboardPage.userDirectory:
        return UserDirectoryPage(currentUser: widget.currentUser);
      case DashboardPage.salesmanActivity:
        return SalesmanActivityPage(currentUser: widget.currentUser);
      case DashboardPage.visitLogs:
        return VisitLogsPage(currentUser: widget.currentUser);
      case DashboardPage.allOrders:
        return AllOrdersPage(currentUser: widget.currentUser, viewOnly: true);
      case DashboardPage.purchaseOrder:
        return PurchaseOrderPage(
          currentUser: widget.currentUser,
          onNavigateRequested: _select,
        );
      case DashboardPage.prediction:
        return PredictionPage(currentUser: widget.currentUser);
      case DashboardPage.reports:
        return ReportsHubPage(currentUser: widget.currentUser);
      case DashboardPage.specialRequests:
        return SpecialRequestsPage(currentUser: widget.currentUser);
      case DashboardPage.retailerScoresheets:
        return RetailerScoreSheetPage(currentUser: widget.currentUser);
      case DashboardPage.departmentPic:
        return DepartmentPicPage(currentUser: widget.currentUser);
      case DashboardPage.product:
        return ProductCmsPage(currentUser: widget.currentUser);
      case DashboardPage.department:
        return DepartmentCmsPage(currentUser: widget.currentUser);
      case DashboardPage.category:
        return CategoryCmsPage(currentUser: widget.currentUser);
      case DashboardPage.websitePages:
        return ContentPagesCmsPage(
          key: ValueKey<String>('content-${page.key}'),
          pageType: page.key,
          currentUser: widget.currentUser,
        );
      case DashboardPage.notifications:
        return DashboardOverviewPage(
          currentUser: widget.currentUser,
          forceNotificationsMode: true,
        );
      case DashboardPage.dashboard:
        return DashboardOverviewPage(
          currentUser: widget.currentUser,
          onNavigateRequested: _select,
        );
      case DashboardPage.salesOrder:
      case DashboardPage.productReport:
      case DashboardPage.monthlyTrend:
      case DashboardPage.trustImpact:
      case DashboardPage.retailer:
      case DashboardPage.coordinateReview:
      case DashboardPage.importPreview:
      case DashboardPage.users:
      case DashboardPage.permissions:
      case DashboardPage.branches:
      case DashboardPage.accountLockouts:
      case DashboardPage.account:
      case DashboardPage.plans:
      case DashboardPage.websiteLogo:
      case DashboardPage.websiteTitle:
      case DashboardPage.terms:
      case DashboardPage.banner:
      case DashboardPage.tax:
      case DashboardPage.systemGovernance:
      case DashboardPage.systemHealth:
      case DashboardPage.auditLog:
      case DashboardPage.teamActionCenter:
      case DashboardPage.teamAiSummary:
      case DashboardPage.teamOrders:
      case DashboardPage.teamVisits:
      case DashboardPage.teamActivity:
      case DashboardPage.teamForecast:
      case DashboardPage.teamReports:
      case DashboardPage.managementActionCenter:
      case DashboardPage.weeklyAiSummary:
        return _notAvailable();
    }
  }
}
