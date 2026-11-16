import '../app/permission_policy.dart';
import '../models/user_profile.dart';
import '../services/permission_policy_service.dart';

bool cmsActionAllowed(
  UserProfile? user,
  String moduleId,
  PermissionAction action,
) {
  if (user == null) return true;
  return PermissionPolicyService.instance.cachedAllows(
    user.role,
    moduleId,
    action,
  );
}
