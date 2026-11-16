import '../app/role_guard.dart';
import 'dashboard_voice_types.dart';

class DashboardVoicePolicyGateway {
  const DashboardVoicePolicyGateway();

  static const Set<String> _supportedRoles = <String>{
    'admin',
    'developer',
    'branch_manager',
    'supervisor',
  };

  DashboardVoicePolicyDecision evaluate({
    required DashboardVoiceInterpretation interpretation,
    required Iterable<DashboardVoicePage> pages,
    required String role,
    required bool isAuthenticated,
    required bool isActive,
    bool featureEnabled = true,
  }) {
    if (!featureEnabled) {
      return const DashboardVoicePolicyDecision.rejected(
        DashboardVoicePolicyFailure.featureDisabled,
      );
    }
    if (!isAuthenticated || role.trim().isEmpty) {
      return const DashboardVoicePolicyDecision.rejected(
        DashboardVoicePolicyFailure.unauthenticated,
      );
    }
    if (!isActive) {
      return const DashboardVoicePolicyDecision.rejected(
        DashboardVoicePolicyFailure.inactiveAccount,
      );
    }
    if (!_supportedRoles.contains(role.trim().toLowerCase())) {
      return const DashboardVoicePolicyDecision.rejected(
        DashboardVoicePolicyFailure.roleNotAllowed,
      );
    }
    if (interpretation.action != DashboardVoiceActionId.openPage) {
      return const DashboardVoicePolicyDecision.rejected(
        DashboardVoicePolicyFailure.unknownAction,
      );
    }

    for (final DashboardVoicePage page in pages) {
      if (page.key == interpretation.pageKey) {
        if (!_roleCanOpenPage(
          role.trim().toLowerCase(),
          interpretation.pageKey,
        )) {
          return const DashboardVoicePolicyDecision.rejected(
            DashboardVoicePolicyFailure.pageNotAllowed,
          );
        }
        return DashboardVoicePolicyDecision.allowed(page);
      }
    }
    return const DashboardVoicePolicyDecision.rejected(
      DashboardVoicePolicyFailure.pageNotAllowed,
    );
  }

  static bool _roleCanOpenPage(String role, String pageKey) {
    if (RoleGuard.isPageHiddenInUserTesting(pageKey)) return false;
    switch (role) {
      case 'developer':
        return true;
      case 'admin':
        return !RoleGuard.developerOnlyKeys.contains(pageKey);
      case 'branch_manager':
        return RoleGuard.branchManagerKeys.contains(pageKey) &&
            !RoleGuard.adminOnlyKeys.contains(pageKey) &&
            !RoleGuard.developerOnlyKeys.contains(pageKey);
      case 'supervisor':
        return RoleGuard.supervisorKeys.contains(pageKey);
      default:
        return false;
    }
  }
}
