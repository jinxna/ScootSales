import '../models/user_profile.dart';
import '../pages/admin/navigation/dashboard_pages.dart';
import '../services/permission_policy_service.dart';
import 'build_flags.dart' as build_flags;
import 'permission_policy.dart';

class RoleGuard {
  const RoleGuard._();

  static final Set<String> developerOnlyKeys = pageKeysFor(
    DashboardRole.developer,
  ).difference(pageKeysFor(DashboardRole.admin));

  static final Set<String> branchManagerKeys = pageKeysFor(
    DashboardRole.branchManager,
  );

  static final Set<String> supervisorKeys = pageKeysFor(
    DashboardRole.supervisor,
  );

  static final Set<String> adminOnlyKeys = pageKeysFor(
    DashboardRole.admin,
  ).difference(branchManagerKeys).difference(supervisorKeys);

  static DashboardPage? pageFor(UserProfile user, String key) {
    if (isPageHiddenInUserTesting(key)) return null;
    final DashboardRole? role = DashboardRole.of(user);
    if (role == null) return null;
    final DashboardPage? page = openablePage(role, key);
    if (page == null) return null;
    final bool allowed =
        role == DashboardRole.developer ||
        (moduleViewGranted(user.role, page.key) &&
            (!navFor(role).writeGrantPages.contains(page) ||
                moduleWriteGranted(user.role, page.key)));
    return allowed ? page : null;
  }

  static String canonicalKey(UserProfile user, String key) {
    final String safe = safePageKey(key);
    final DashboardRole? role = DashboardRole.of(user);
    return role == null ? safe : openablePage(role, safe)?.key ?? safe;
  }

  static bool canAccess(UserProfile user, String key) =>
      pageFor(user, key) != null;

  static bool isPageHiddenInUserTesting(String key) =>
      build_flags.isPageHiddenInUserTesting(key);

  static String safePageKey(String key) =>
      isPageHiddenInUserTesting(key) ? landingKey : key;

  static bool moduleViewGranted(String role, String pageKey) {
    final PermissionModule? module = PermissionModuleRegistry.forPageKey(
      pageKey,
    );
    if (module == null) return true;
    return PermissionPolicyService.instance.cachedAllows(
      role,
      module.id,
      PermissionAction.view,
    );
  }

  static bool moduleWriteGranted(String role, String pageKey) {
    final PermissionModule? module = PermissionModuleRegistry.forPageKey(
      pageKey,
    );
    return module != null &&
        PermissionPolicyService.instance.cachedAllowsWrite(role, module.id);
  }

  static final String landingKey = DashboardPage.landing.key;
}
