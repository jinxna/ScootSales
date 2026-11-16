import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../app/role_guard.dart';
import '../../app/build_flags.dart';
import '../../app/browser_page_history.dart';
import '../../app/browser_page_history_session.dart';
import '../../app/web_page_route.dart';
import '../../app_runtime.dart';
import '../../models/user_profile.dart';
import '../../services/auth_service.dart';
import '../../services/order_submission_alerts.dart';
import '../../services/permission_policy_service.dart';
import 'navigation/cms_navigation.dart';
import 'navigation/dashboard_pages.dart';
import 'navigation/page_not_available.dart';
import 'widgets/cms_command_palette.dart';
import 'views/all_orders_page.dart';
import 'views/audit_log_page.dart';
import 'views/account_lockouts_page.dart';
import 'views/branch_management_cms_page.dart';
import 'views/category_cms_page.dart';
import 'views/content_pages_cms_page.dart';
import 'views/coordinate_review_page.dart';
import 'views/dashboard_overview_page.dart';
import 'views/department_cms_page.dart';
import 'views/department_pic_page.dart';
import 'views/import_preview_page.dart';
import 'views/product_cms_page.dart';
import 'views/prediction_page.dart';
import 'views/purchase_order_page.dart';
import 'views/reports_hub_page.dart';
import 'views/retailer_management_cms_page.dart';
import 'views/route_planner_page.dart';
import 'views/retailer_score_sheet_page.dart';
import 'views/salesman_activity_page.dart';
import 'views/user_directory_page.dart';
import 'views/user_management_cms_page.dart';
import 'views/permission_matrix_page.dart';
import 'views/visit_logs_page.dart';
import 'views/special_requests_page.dart';
import '../legal_documents_page.dart';
import 'views/account_cms_page.dart';
import 'views/plans_cms_page.dart';
import 'views/system_governance_page.dart';
import 'views/system_health_page.dart';
import 'views/trust_impact_page.dart';
import '../../services/ai_alert_service.dart';
import '../../widgets/dashboard_chrome.dart';
import '../../../voice/dashboard_voice_catalog.dart';
import '../../../voice/copilot/copilot_client.dart';
import '../../../voice/copilot/copilot_panel.dart';
import '../../../voice/copilot/copilot_status.dart';

class AdminCmsShellPage extends StatefulWidget {
  const AdminCmsShellPage({super.key, required this.currentUser});

  final UserProfile currentUser;

  @override
  State<AdminCmsShellPage> createState() => _AdminCmsShellPageState();
}

class _AdminCmsShellPageState extends State<AdminCmsShellPage> {
  late String _selectedKey;
  void Function()? _cancelBrowserHistorySubscription;

  bool _copilotOpen = false;
  late final CopilotServerClient? _copilotServer =
      copilotServerFromEnvironment();
  late final CopilotServerStatus _copilotStatus = CopilotServerStatus(
    _copilotServer,
  );
  final GlobalKey _copilotPanelKey = GlobalKey();
  OrderSubmissionAlerts? _orderAlerts;
  late final Stream<int>? _notificationBadge =
      !isBasicEdition && widget.currentUser.isAdmin
      ? AiAlertService().watchAdminHighPriorityCount()
      : null;

  String get _sessionUid => widget.currentUser.uid ?? widget.currentUser.docId;

  @override
  void initState() {
    super.initState();
    unawaited(_copilotStatus.wake());
    if (widget.currentUser.isAdmin) {
      PermissionPolicyService.instance.startSession();
      PermissionPolicyService.instance.policy.addListener(_handlePolicyChanged);
    }
    _startOrderAlerts();
    _selectedKey = sessionPageKey(_sessionUid, _canonicalKey);
    _cancelBrowserHistorySubscription = listenForBrowserPageChanges(() {
      if (!mounted) return;
      setState(() => _selectedKey = sessionPageKey(_sessionUid, _canonicalKey));
    });
  }

  void _startOrderAlerts() {
    if (_orderAlerts != null ||
        !AppRuntime.firebaseReady ||
        !widget.currentUser.isAdmin) {
      return;
    }
    _orderAlerts = OrderSubmissionAlerts(onAlert: _showOrderAlert)
      ..start(
        OrderSubmissionAlerts.firestoreChanges(FirebaseFirestore.instance),
      );
  }

  @override
  void dispose() {
    _copilotStatus.dispose();
    PermissionPolicyService.instance.policy.removeListener(
      _handlePolicyChanged,
    );
    unawaited(_orderAlerts?.dispose());
    _cancelBrowserHistorySubscription?.call();
    super.dispose();
  }

  void _handlePolicyChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _showOrderAlert(OrderAlert alert) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(alert.message),
        action: SnackBarAction(
          label: 'View orders',
          onPressed: () => _select('all_orders'),
        ),
      ),
    );
  }

  String _canonicalKey(String key) =>
      RoleGuard.canonicalKey(widget.currentUser, key);

  void _select(String key) {
    final String safeKey = _canonicalKey(key);
    if (_selectedKey == safeKey) return;
    pushBrowserPageFragment(fragmentForPageKey(safeKey), uid: _sessionUid);
    setState(() => _selectedKey = safeKey);
  }

  void _openCommandPalette() {
    showCmsCommandPalette(
      context: context,
      items: cmsSearchItems(widget.currentUser.role),
      currentKey: _selectedKey,
      onSelected: _select,
    );
  }

  void _toggleCopilot() => setState(() => _copilotOpen = !_copilotOpen);

  @override
  Widget build(BuildContext context) {
    final DashboardRole? role = DashboardRole.of(widget.currentUser);
    final DashboardPage? page = RoleGuard.pageFor(
      widget.currentUser,
      _selectedKey,
    );
    final CmsNavItem? navItem = role == null || page == null
        ? null
        : cmsNavItemFor(role, page);
    final List<CmsNavSection> sections = cmsSidebarSections(
      widget.currentUser.role,
    );
    return Scaffold(
      body: StreamBuilder<int>(
        stream: _notificationBadge,
        builder: (BuildContext context, AsyncSnapshot<int> badge) {
          return DashboardChrome(
            user: widget.currentUser,
            groups: scootNavGroups(
              sections,
              badgeKey: DashboardPage.notifications.key,
              badgeCount: badge.data ?? 0,
              badgeLabel: 'high priority',
            ),
            selectedId: page?.key,
            onSelect: _select,
            scopeLabel: 'All branches',
            onSearch: _openCommandPalette,
            copilotStatus: _copilotStatus,
            copilotOpen: _copilotOpen,
            onCopilot: _toggleCopilot,
            onSignOut: () => AuthService.instance.signOut(),
            pageTitle: page == DashboardPage.dashboard
                ? ''
                : navItem?.title ?? pageNotAvailableTitle,
            pageFact: navItem?.description ?? pageNotAvailableMessage,
            untitledPageName: page == DashboardPage.dashboard
                ? navItem?.title ?? ''
                : '',
            showBeta:
                kUserTestingMode && page != null && isBetaPageKey(page.key),
            notices: <Widget>[
              if (!AppRuntime.firebaseReady)
                const ScootNotice(
                  tone: ScootTone.warning,
                  message:
                      'Shared data connection is not ready. Add the project configuration to view shared records.',
                ),
            ],
            copilotPanelBuilder: (bool fill) => CopilotPanel(
              key: _copilotPanelKey,
              fill: fill,
              currentUser: widget.currentUser,
              pages: dashboardVoicePagesFromCms(
                cmsSearchItems(widget.currentUser.role),
              ),
              onPageRequested: (String key) async {
                if (mounted) _select(key);
              },
              onClose: _toggleCopilot,
              status: _copilotStatus,
              server: _copilotServer,
            ),
            child: _selectable(
              page == null ? _notAvailable() : _buildSelectedPage(page),
            ),
          );
        },
      ),
    );
  }

  Widget _selectable(Widget page) => _selectedKey == 'route_planner'
      ? SelectionContainer.disabled(child: page)
      : SelectionArea(child: page);

  Widget _notAvailable() => PageNotAvailable(
    requestedKey: _selectedKey,
    landingLabel: 'Dashboard',
    onOpenLanding: () => _select(RoleGuard.landingKey),
  );

  Widget _buildSelectedPage(DashboardPage page) {
    switch (page) {
      case DashboardPage.dashboard:
        return DashboardOverviewPage(
          currentUser: widget.currentUser,
          onNavigateRequested: _select,
        );
      case DashboardPage.salesmanActivity:
        return SalesmanActivityPage(currentUser: widget.currentUser);
      case DashboardPage.routePlanner:
        return RoutePlannerPage(
          currentUser: widget.currentUser,
          onNavigateRequested: _select,
        );
      case DashboardPage.visitLogs:
        return VisitLogsPage(currentUser: widget.currentUser);
      case DashboardPage.notifications:
        return DashboardOverviewPage(
          currentUser: widget.currentUser,
          forceNotificationsMode: true,
        );
      case DashboardPage.allOrders:
      case DashboardPage.salesOrder:
        return AllOrdersPage(currentUser: widget.currentUser);
      case DashboardPage.reports:
      case DashboardPage.productReport:
      case DashboardPage.monthlyTrend:
        return ReportsHubPage(
          currentUser: widget.currentUser,
          onNavigateRequested: _select,
        );
      case DashboardPage.users:
        return UserManagementCmsPage(
          currentUser: widget.currentUser,
          onOpenBranches: () => _select(DashboardPage.branches.key),
        );
      case DashboardPage.userDirectory:
        return UserDirectoryPage(currentUser: widget.currentUser);
      case DashboardPage.permissions:
        return PermissionMatrixPage(currentUser: widget.currentUser);
      case DashboardPage.branches:
        return BranchManagementCmsPage(currentUser: widget.currentUser);
      case DashboardPage.retailer:
        return RetailerManagementCmsPage(
          currentUser: widget.currentUser,
          onOpenRoutePlanner: () => _select(DashboardPage.routePlanner.key),
        );
      case DashboardPage.coordinateReview:
        return CoordinateReviewPage(currentUser: widget.currentUser);
      case DashboardPage.importPreview:
        return ImportPreviewPage(currentUser: widget.currentUser);
      case DashboardPage.retailerScoresheets:
        return RetailerScoreSheetPage(currentUser: widget.currentUser);
      case DashboardPage.department:
        return DepartmentCmsPage(currentUser: widget.currentUser);
      case DashboardPage.category:
        return CategoryCmsPage(currentUser: widget.currentUser);
      case DashboardPage.product:
        return ProductCmsPage(currentUser: widget.currentUser);
      case DashboardPage.departmentPic:
        return DepartmentPicPage(currentUser: widget.currentUser);
      case DashboardPage.specialRequests:
        return SpecialRequestsPage(currentUser: widget.currentUser);
      case DashboardPage.prediction:
        return PredictionPage(currentUser: widget.currentUser);
      case DashboardPage.trustImpact:
        return TrustImpactPage(currentUser: widget.currentUser);
      case DashboardPage.systemGovernance:
        return SystemGovernancePage(currentUser: widget.currentUser);
      case DashboardPage.systemHealth:
        return SystemHealthPage(
          currentUser: widget.currentUser,
          onNavigateRequested: _select,
        );
      case DashboardPage.auditLog:
        return AuditLogPage(currentUser: widget.currentUser);
      case DashboardPage.accountLockouts:
        return AccountLockoutsPage(currentUser: widget.currentUser);
      case DashboardPage.websitePages:
      case DashboardPage.websiteTitle:
      case DashboardPage.websiteLogo:
      case DashboardPage.terms:
      case DashboardPage.banner:
      case DashboardPage.tax:
        return ContentPagesCmsPage(
          key: ValueKey<String>('content-${page.key}'),
          pageType: page.key,
        );
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
      case DashboardPage.account:
        return AccountCmsPage(
          onChangePlan: () => _select(DashboardPage.plans.key),
        );
      case DashboardPage.plans:
        return const PlansCmsPage();
      case DashboardPage.purchaseOrder:
        return PurchaseOrderPage(
          currentUser: widget.currentUser,
          onNavigateRequested: _select,
        );
      case DashboardPage.myTeam:
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
