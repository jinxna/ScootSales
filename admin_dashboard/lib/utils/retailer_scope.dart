import '../models/user_profile.dart';

bool retailerAssignedToCode(Map<String, dynamic> retailer, String code) {
  if (code.isEmpty) return false;
  if (retailer['assignedSalesmanId'] == code) return true;
  final Object? listed = retailer['assignedSalesmanCodes'];
  return listed is List && listed.contains(code);
}

bool retailerInActorScope(UserProfile? user, Map<String, dynamic> retailer) {
  if (user == null || user.isAdmin) return true;
  if (user.isSupervisor) {
    return user.assignedSalesmanCodes.any(
      (String code) => retailerAssignedToCode(retailer, code),
    );
  }
  if (user.isBranchManager) {
    final String branchId = user.branchId.trim();
    final Object? retailerBranch =
        retailer['branchId'] ?? retailer['branch_id'];
    return branchId.isNotEmpty && retailerBranch == branchId;
  }
  return false;
}
