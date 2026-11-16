import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/browser_page_history.dart';
import '../../app_runtime.dart';
import '../../models/user_profile.dart';
import '../../security/profile_gate.dart';
import '../../services/auth_service.dart';
import '../../services/dashboard_access_session.dart';
import '../../utils/user_facing_error.dart';
import '../../widgets/console_notices.dart';
import '../auth/login_page.dart';
import '../auth/platform_access_page.dart';
import '../branch_manager/branch_manager_shell_page.dart';
import '../supervisor/supervisor_shell_page.dart';
import 'admin_cms_shell_page.dart';
import 'restricted_workspace_page.dart';

class AdminWebRouterPage extends StatelessWidget {
  const AdminWebRouterPage({super.key, required this.session});

  final DashboardAccessSession session;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) {
      return const _WrongPlatformPage();
    }
    if (!AppRuntime.firebaseReady) {
      return LoginPage(onSignedIn: session.retry);
    }
    if (!session.authReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (session.user == null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => replaceBrowserPageFragment(''),
      );
      return LoginPage(onSignedIn: session.retry);
    }

    final AsyncSnapshot<UserProfile?> profileSnapshot = session.profile;
    final UserProfile? profile = profileSnapshot.data;
    final ProfileGateState gate = decideProfileGate(
      waiting: profileSnapshot.connectionState == ConnectionState.waiting,
      failed: profileSnapshot.hasError,
      role: profile?.role ?? '',
      active: profile?.isActive ?? false,
    );
    final bool restricted = session.workspaceRestricted;
    if (session.lifecyclePending &&
        (gate == ProfileGateState.adminConsole ||
            gate == ProfileGateState.supervisorConsole ||
            gate == ProfileGateState.branchManagerConsole)) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (restricted &&
        (gate == ProfileGateState.supervisorConsole ||
            gate == ProfileGateState.branchManagerConsole)) {
      return PlatformAccessPage(
        title: 'Workspace not active',
        message:
            'This company workspace is not active. Only an administrator can '
            'sign in, to download the company data or grant support access.',
        profile: profile!,
      );
    }
    switch (gate) {
      case ProfileGateState.waiting:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case ProfileGateState.lookupFailed:
        return ProfileLookupFailedPage(
          onRetry: session.retry,
          error: profileSnapshot.error,
        );
      case ProfileGateState.missingProfile:
        return const _MissingProfilePage();
      case ProfileGateState.suspended:
        return PlatformAccessPage(
          title: 'Account Suspended',
          message: 'This account is suspended. Please contact the admin.',
          profile: profile!,
        );
      case ProfileGateState.salesmanOnWebPortal:
        return PlatformAccessPage(
          title: 'Salesman accounts should use the mobile app',
          message:
              'This portal is for Admin, Supervisor and Branch Manager accounts. '
              'Please sign in to the salesman mobile app instead.',
          profile: profile!,
        );
      case ProfileGateState.supervisorConsole:
        return _withPastDueBanner(SupervisorShellPage(currentUser: profile!));
      case ProfileGateState.branchManagerConsole:
        return _withPastDueBanner(BranchManagerShellPage(currentUser: profile!));
      case ProfileGateState.adminConsole:
        return restricted
            ? RestrictedWorkspacePage(
                currentUser: profile!,
                lifecycleState: session.lifecycleState,
                retentionEndsAt: session.lifecycleRetentionEndsAt,
              )
            : _withPastDueBanner(AdminCmsShellPage(currentUser: profile!));
      case ProfileGateState.unknownRole:
        return const _AuthStateErrorPage(
          title: 'Unknown Role',
          message:
              'This account signed in successfully, but its role is missing or '
              'not supported for the admin website. Please sign out and log in '
              'again with a valid website account.',
        );
    }
  }
}

extension on AdminWebRouterPage {
  Widget _withPastDueBanner(Widget console) => ConsoleNotices(
    state: session.lifecycleState,
    graceEndsAt: session.lifecycleGraceEndsAt,
    roleChange: session.roleChangeNotice,
    onDismissRoleChange: session.dismissRoleChangeNotice,
    isAdmin: session.profile.data?.isAdmin ?? false,
    child: console,
  );
}

class _WrongPlatformPage extends StatelessWidget {
  const _WrongPlatformPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text(
          'This package is meant to be opened in a desktop browser, for example Chrome or Edge.',
        ),
      ),
    );
  }
}

class _MissingProfilePage extends StatelessWidget {
  const _MissingProfilePage();

  @override
  Widget build(BuildContext context) {
    return const _AuthStateErrorPage(
      title: 'No Profile Found',
      message:
          'Create a user profile with the same email, then add fields like role, employee code, name, status, branch, and supervisor.',
    );
  }
}

class ProfileLookupFailedPage extends StatelessWidget {
  const ProfileLookupFailedPage({super.key, required this.onRetry, this.error});

  final VoidCallback onRetry;
  final Object? error;

  String get _backend => AppRuntime.usesLocalEmulator
      ? 'the local test server at ${AppRuntime.emulatorHost}'
      : 'the server';

  String get _detail {
    final Object? failure = error;
    if (failure == null) return '';
    return userFacingError(failure, action: 'load your profile');
  }

  @override
  Widget build(BuildContext context) {
    final String detail = _detail;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.cloud_off_rounded,
                    size: 36,
                    color: scheme.onTertiaryContainer,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Could not load your profile',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Signed in, but no profile could be read from $_backend. Either '
                    'this account has no profile yet, or the lookup itself did not '
                    'complete. Check the connection and try again before creating one.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      height: 1.6,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (detail.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        detail,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  if (AppRuntime.backendWarning.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      AppRuntime.backendWarning,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onTertiaryContainer,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: () async => AuthService.instance.signOut(),
                        icon: const Icon(Icons.logout_rounded),
                        label: const Text('Sign Out'),
                      ),
                      FilledButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try Again'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthStateErrorPage extends StatelessWidget {
  const _AuthStateErrorPage({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      height: 1.6,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: () async => AuthService.instance.signOut(),
                        icon: const Icon(Icons.arrow_back_rounded),
                        label: const Text('Go Back to Login'),
                      ),
                      FilledButton(
                        onPressed: () async => AuthService.instance.signOut(),
                        child: const Text('Sign Out'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
