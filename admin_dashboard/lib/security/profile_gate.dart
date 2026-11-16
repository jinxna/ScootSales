enum ProfileGateState {
  waiting,

  lookupFailed,

  missingProfile,

  suspended,

  salesmanOnWebPortal,
  supervisorConsole,
  branchManagerConsole,
  adminConsole,

  unknownRole,
}

ProfileGateState decideProfileGate({
  required bool waiting,
  required bool failed,
  required String role,
  required bool active,
}) {
  if (waiting) return ProfileGateState.waiting;
  if (failed) return ProfileGateState.lookupFailed;
  if (role.isEmpty) return ProfileGateState.missingProfile;
  if (!active) return ProfileGateState.suspended;
  switch (role) {
    case 'salesman':
      return ProfileGateState.salesmanOnWebPortal;
    case 'supervisor':
      return ProfileGateState.supervisorConsole;
    case 'branch_manager':
      return ProfileGateState.branchManagerConsole;
    case 'admin':
    case 'developer':
      return ProfileGateState.adminConsole;
  }
  return ProfileGateState.unknownRole;
}
