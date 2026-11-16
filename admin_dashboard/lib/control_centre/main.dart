import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../app/idle_timeout.dart';
import 'pages/account_page.dart';
import 'pages/audit_page.dart';
import 'pages/companies_page.dart';
import 'pages/company_page.dart';
import 'pages/help_page.dart';
import 'pages/inbox_page.dart';
import 'pages/invite_page.dart';
import 'pages/invoices_page.dart';
import 'pages/new_company_page.dart';
import 'pages/onboarding_page.dart';
import 'pages/packages_page.dart';
import 'pages/payments_page.dart';
import 'pages/settings_page.dart';
import 'pages/signin_page.dart';
import 'pages/staff_page.dart';
import 'pages/support_home_page.dart';
import 'staff_api_client.dart';
import 'staff_auth.dart';
import 'staff_browser.dart';
import 'store/cc_store.dart';
import 'widgets/cc_common.dart';
import 'widgets/cc_nav.dart';
import 'widgets/cc_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('USE_FIREBASE_EMULATOR')) {
    SemanticsBinding.instance.ensureSemantics();
  }
  runApp(const ControlCentreApp());
}

class ControlCentreApp extends StatefulWidget {
  const ControlCentreApp({super.key});

  @override
  State<ControlCentreApp> createState() => _ControlCentreAppState();
}

class _ControlCentreAppState extends State<ControlCentreApp> {
  final StaffAuth _auth = StaffAuth();
  late final StaffApiClient _api = StaffApiClient(
    headers: _auth.headers,
    onSessionLost: _auth.sessionLost,
  );
  String? _inviteToken;

  @override
  void initState() {
    super.initState();
    _auth.api = _api;
    final String fragment = urlFragment();
    if (fragment.startsWith('#staffInvite=')) {
      _inviteToken = fragment.substring('#staffInvite='.length);
      clearUrlFragment();
    }
    _auth.start();
  }

  @override
  void dispose() {
    _auth.dispose();
    _api.close();
    super.dispose();
  }

  Widget _body() {
    if (_inviteToken != null) {
      return InvitePage(
        api: _api,
        token: _inviteToken!,
        onDone: () => setState(() => _inviteToken = null),
      );
    }
    return ListenableBuilder(
      listenable: _auth,
      builder: (BuildContext context, Widget? _) => switch (_auth.step) {
        StaffAuthStep.starting => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
        StaffAuthStep.signedIn => ControlCentreHome(api: _api, auth: _auth),
        _ => SignInPage(auth: _auth),
      },
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Scoot Sales Control Centre',
    debugShowCheckedModeBanner: false,
    theme: Cc.theme(),
    home: IdleTimeout(
      authStateChanges: _auth.userChanges,
      onTimeout: () => _auth.signOutIdle(kSessionIdleTimeout.inMinutes),
      child: _body(),
    ),
  );
}

class ControlCentreHome extends StatefulWidget {
  const ControlCentreHome({super.key, required this.api, required this.auth});

  final StaffApiClient api;
  final StaffAuth auth;

  @override
  State<ControlCentreHome> createState() => _ControlCentreHomeState();
}

class _ControlCentreHomeState extends State<ControlCentreHome> {
  late final CcStore _store = CcStore(widget.api);
  bool _loading = true;
  String? _error;
  CcSection _section = CcSection.inbox;
  String? _tenantId, _invoiceId, _onboardingTenant, _query;
  int _companyTab = CompanyTab.overview;
  int _epoch = 0;
  late String? _signInNotice = widget.auth.notice;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _store.loadProfile();
      final StaffProfile profile = _store.profile!;
      if (profile.seesCommercialData) {
        if (profile.canManageAccounts) {
          _store.loadAll();
        } else {
          _store.refreshCompanies();
          _store.refreshDrafts();
        }
      }
      if (profile.can(CcSection.supportHome.name)) {
        _store.refreshSupportGrants();
      }
      _section = homeSection(profile);
      if (!mounted) return;
      setState(() => _loading = false);
    } on StaffApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'The staff service returned an invalid response.';
      });
    }
  }

  void _go(
    CcSection section, {
    String? tenantId,
    String? invoiceId,
    String? onboarding,
    String? query,
    int tab = CompanyTab.overview,
  }) {
    setState(() {
      _section = section;
      _tenantId = tenantId;
      _invoiceId = invoiceId;
      _onboardingTenant = onboarding;
      _query = query;
      _companyTab = tab;
      _epoch++;
    });
  }

  late final CcNav _nav = CcNav(
    go: (CcSection section) => _go(section),
    openCompany: (String tenantId, {int tab = CompanyTab.overview}) =>
        _go(CcSection.companies, tenantId: tenantId, tab: tab),
    openInvoice: (String invoiceId) =>
        _go(CcSection.invoices, invoiceId: invoiceId),
    openOnboarding: (String draftId) =>
        _go(CcSection.onboarding, onboarding: draftId),
  );

  void _search(String text) {
    if (text.isEmpty) return;
    if (RegExp(r'^(INV|CN)-', caseSensitive: false).hasMatch(text)) {
      _go(CcSection.invoices, query: text);
    } else {
      _go(CcSection.companies, query: text);
    }
  }

  void _signOut() => widget.auth.signOut();

  Map<CcSection, int> _counts() => <CcSection, int>{
    CcSection.inbox: _store.inboxItems().length,
    CcSection.onboarding: _store.openDrafts.length,
    CcSection.invoices: (_store.invoices?.value ?? const <StaffInvoice>[])
        .where((StaffInvoice i) => i.isDraft)
        .length,
    CcSection.payments: _store.toCheck?.value?.length ?? 0,
  };

  Widget _page(StaffProfile profile) {
    if (_section != CcSection.account &&
        _section != CcSection.newCompany &&
        _section != CcSection.help &&
        !profile.can(_section.name)) {
      return const CcPage(
        child: CcEmptyState(
          title: 'This section is not assigned to your role.',
          message: 'Choose a section from the side menu.',
        ),
      );
    }
    final ValueKey<String> key = ValueKey<String>('${_section.name}-$_epoch');
    return switch (_section) {
      CcSection.inbox => InboxPage(key: key, store: _store, nav: _nav),
      CcSection.companies =>
        _tenantId != null
            ? CompanyPage(
                key: key,
                store: _store,
                nav: _nav,
                tenantId: _tenantId!,
                initialTab: _companyTab,
              )
            : CompaniesPage(
                key: key,
                store: _store,
                nav: _nav,
                initialQuery: _query ?? '',
              ),
      CcSection.onboarding => OnboardingPage(
        key: key,
        store: _store,
        nav: _nav,
        draftId: _onboardingTenant,
      ),
      CcSection.newCompany => NewCompanyPage(
        key: key,
        store: _store,
        nav: _nav,
      ),
      CcSection.invoices => InvoicesPage(
        key: key,
        store: _store,
        nav: _nav,
        initialInvoiceId: _invoiceId,
        initialQuery: _query ?? '',
      ),
      CcSection.payments => PaymentsPage(key: key, store: _store, nav: _nav),
      CcSection.packages => PackagesPage(key: key, store: _store, nav: _nav),
      CcSection.staff => StaffPage(key: key, store: _store),
      CcSection.audit => AuditPage(key: key, store: _store, nav: _nav),
      CcSection.settings => SettingsPage(key: key, store: _store),
      CcSection.supportHome => SupportHomePage(key: key, store: _store),
      CcSection.help => StaffHelpPage(key: key),
      CcSection.account => AccountPage(
        key: key,
        store: _store,
        auth: widget.auth,
        onSignOut: _signOut,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final StaffProfile? profile = _store.profile;
    if (profile == null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(_error ?? 'Could not load your staff profile.'),
                const SizedBox(height: 12),
                FilledButton(onPressed: _start, child: const Text('Try again')),
              ],
            ),
          ),
        ),
      );
    }
    return ListenableBuilder(
      listenable: _store,
      builder: (BuildContext context, Widget? _) => CcShell(
        profile: profile,
        section: _section == CcSection.newCompany
            ? CcSection.companies
            : _section,
        counts: _counts(),
        onSelect: (CcSection section) => _go(section),
        onSearch: _search,
        onSignOut: _signOut,
        child: _signInNotice == null
            ? _page(profile)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                    child: CcBanner(
                      text: _signInNotice!,
                      tone: Tone.info,
                      action: TextButton(
                        onPressed: () => setState(() => _signInNotice = null),
                        child: const Text('Dismiss'),
                      ),
                    ),
                  ),
                  Expanded(child: _page(profile)),
                ],
              ),
      ),
    );
  }
}
