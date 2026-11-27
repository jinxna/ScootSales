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
import '../../services/ai_alert_service.dart';
import '../../services/permission_policy_service.dart';
import '../admin/navigation/cms_navigation.dart';
import '../admin/navigation/dashboard_pages.dart';
import '../admin/navigation/page_not_available.dart';
import '../admin/widgets/cms_command_palette.dart';
import '../admin/views/all_orders_page.dart';
import '../admin/views/dashboard_overview_page.dart';
import '../admin/views/management_action_center_panel.dart';
import '../admin/views/my_team_page.dart';
import '../admin/views/prediction_page.dart';
import '../admin/views/reports_hub_page.dart';
import '../admin/views/route_planner_page.dart';
import '../admin/views/salesman_activity_page.dart';
import '../admin/views/category_cms_page.dart';
import '../admin/views/content_pages_cms_page.dart';
import '../admin/views/department_cms_page.dart';
import '../admin/views/department_pic_page.dart';
import '../admin/views/product_cms_page.dart';
import '../admin/views/retailer_score_sheet_page.dart';
import '../admin/views/special_requests_page.dart';
import '../admin/views/visit_logs_page.dart';
import '../admin/views/weekly_ai_summary_panel.dart';
import '../../widgets/dashboard_chrome.dart';
import '../legal_documents_page.dart';
import '../../voice/dashboard_voice_catalog.dart';
import '../../voice/copilot/copilot_client.dart';
import '../../voice/copilot/copilot_panel.dart';
import '../../voice/copilot/copilot_status.dart';
import '../../voice/dashboard_voice_types.dart';

class SupervisorShellPage extends StatefulWidget {
  const SupervisorShellPage({super.key, required this.currentUser});

  final UserProfile currentUser;

  @override
  State<SupervisorShellPage> createState() => _SupervisorShellPageState();
}

class _SupervisorShellPageState extends State<SupervisorShellPage> {
  late String _selectedKey;
  final PlannerOpenRequests _plannerRequests = PlannerOpenRequests();
  void Function()? _cancelBrowserHistorySubscription;
  bool _copilotOpen = false;
  late final CopilotServerClient? _copilotServer =
      copilotServerFromEnvironment();
  late final CopilotServerStatus _copilotStatus = CopilotServerStatus(
    _copilotServer,
  );
  final GlobalKey _copilotPanelKey = GlobalKey();
  late final Stream<int> _actionCenterOpenStream = isBasicEdition
      ? Stream<int>.value(0)
      : AiAlertService().watchActionCenterOpenCount(widget.currentUser);

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
  void didUpdateWidget(covariant SupervisorShellPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(
          oldWidget.currentUser.assignedSalesmanCodes,
          widget.currentUser.assignedSalesmanCodes,
        ) ||
        oldWidget.currentUser.branchId != widget.currentUser.branchId) {
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
          onPressed: () => _select(
            alert.specialRequest ? 'special_requests' : 'team_orders',
          ),
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

  void _openFromMyTeam(MyTeamDestination destination, String salesmanUid) {
    switch (destination) {
      case MyTeamDestination.orders:
        _select('team_orders');
      case MyTeamDestination.visits:
        _select('team_visits');
      case MyTeamDestination.activity:
        _select('team_activity');
      case MyTeamDestination.routePlanner:
        setState(() => _plannerRequests.post(salesmanUid: salesmanUid));
        _select('route_planner');
    }
  }

  Future<bool> _openPlannerFromCopilot(
    String salesmanUid,
    DateTime weekStart,
  ) async {
    if (!mounted) return false;
    setState(
      () =>
          _plannerRequests.post(salesmanUid: salesmanUid, weekStart: weekStart),
    );
    _select('route_planner');
    return true;
  }

  List<DashboardVoicePage> get _copilotPages =>
      cmsSearchItems(DashboardRole.supervisor.wire)
          .map(
            (CmsNavItem item) => dashboardVoicePage(
              key: item.key,
              label: item.label,
              description: item.description,
              aliases: item.keywords,
            ),
          )
          .toList(growable: false);

  void _toggleCopilot() => setState(() => _copilotOpen = !_copilotOpen);

  DashboardPage? get _page =>
      RoleGuard.pageFor(widget.currentUser, _selectedKey);

  CmsNavItem? get _current {
    final DashboardPage? page = _page;
    return page == null ? null : cmsNavItemFor(DashboardRole.supervisor, page);
  }

  bool get _hasTeam => widget.currentUser.assignedSalesmanCodes.isNotEmpty;

  void _openCommandPalette() {
    showCmsCommandPalette(
      context: context,
      items: cmsSearchItems(DashboardRole.supervisor.wire),
      currentKey: _selectedKey,
      onSelected: _select,
    );
  }

  @override
  Widget build(BuildContext context) {
    final CmsNavItem? current = _current;
    final int teamSize = widget.currentUser.assignedSalesmanCodes.length;
    return Scaffold(
      body: StreamBuilder<int>(
        stream: _actionCenterOpenStream,
        builder: (BuildContext context, AsyncSnapshot<int> snapshot) {
          return DashboardChrome(
            user: widget.currentUser,
            groups: scootNavGroups(
              cmsSidebarSections(DashboardRole.supervisor.wire),
              badgeKey: DashboardPage.teamActionCenter.key,
              badgeCount: snapshot.data ?? 0,
              badgeLabel: 'open',
            ),
            selectedId: _page?.key,
            onSelect: _select,
            scopeLabel: teamSize > 0
                ? '$teamSize sales rep${teamSize == 1 ? '' : 's'} assigned'
                : 'No team assigned',
            onSearch: _openCommandPalette,
            copilotStatus: _copilotStatus,
            copilotOpen: _copilotOpen,
            onCopilot: _toggleCopilot,
            onSignOut: () => AuthService.instance.signOut(),
            pageTitle: current?.page == DashboardPage.dashboard
                ? ''
                : current?.title ?? pageNotAvailableTitle,
            pageFact: current?.headerFact ?? pageNotAvailableMessage,
            untitledPageName: current?.page == DashboardPage.dashboard
                ? current?.title ?? ''
                : '',
            showBeta:
                kUserTestingMode &&
                current != null &&
                isBetaPageKey(current.key),
            notices: <Widget>[
              if (!_hasTeam)
                const ScootNotice(
                  tone: ScootTone.warning,
                  title: 'No salesmen assigned to you yet',
                  message:
                      'Ask an admin to set your "assignedSalesmanCodes" (and the salesmen "supervisorId") in User Management. Until then, team orders, visits and activity stay empty. Your console never shows data of other teams.',
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
              onPlannerRequested: _openPlannerFromCopilot,
            ),
            child: _selectable(
              _page == null ? _notAvailable() : _buildSelectedPage(_page!),
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
    landingLabel: 'Team Overview',
    onOpenLanding: () => _select(RoleGuard.landingKey),
  );

  Widget _buildSelectedPage(DashboardPage page) {
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
      case DashboardPage.teamOrders:
        return AllOrdersPage(currentUser: widget.currentUser);
      case DashboardPage.teamVisits:
        return VisitLogsPage(currentUser: widget.currentUser);
      case DashboardPage.teamActivity:
        return SalesmanActivityPage(currentUser: widget.currentUser);
      case DashboardPage.teamForecast:
        return PredictionPage(currentUser: widget.currentUser);
      case DashboardPage.teamReports:
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
      case DashboardPage.teamActionCenter:
        return ManagementActionCenterPanel(
          currentUser: widget.currentUser,
          onNavigateRequested: _select,
        );
      case DashboardPage.teamAiSummary:
        return WeeklyAiSummaryPanel(currentUser: widget.currentUser);
      case DashboardPage.myTeam:
        return MyTeamPage(
          currentUser: widget.currentUser,
          onNavigate: _openFromMyTeam,
        );
      case DashboardPage.routePlanner:
        return RoutePlannerPage(
          currentUser: widget.currentUser,
          openRequests: _plannerRequests,
          onNavigateRequested: _select,
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
      case DashboardPage.allOrders:
      case DashboardPage.salesOrder:
      case DashboardPage.purchaseOrder:
      case DashboardPage.salesmanActivity:
      case DashboardPage.visitLogs:
      case DashboardPage.reports:
      case DashboardPage.productReport:
      case DashboardPage.monthlyTrend:
      case DashboardPage.prediction:
      case DashboardPage.trustImpact:
      case DashboardPage.retailer:
      case DashboardPage.coordinateReview:
      case DashboardPage.importPreview:
      case DashboardPage.userDirectory:
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
      case DashboardPage.managementActionCenter:
      case DashboardPage.weeklyAiSummary:
        return _notAvailable();
    }
  }
}
