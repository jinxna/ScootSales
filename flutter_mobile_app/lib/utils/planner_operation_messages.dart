String plannerDeleteFailureMessage(Object error) {
  if (error.toString().contains('permission-denied')) {
    return 'Visit could not be deleted because this account does not have access.';
  }
  return 'Visit could not be deleted. Check your connection and try again.';
}
