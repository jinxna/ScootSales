class SalespersonCartLimits {
  SalespersonCartLimits._();

  static const int maxDistinctItems = 5;

  static bool canAddDistinctItems({
    required int selectedCount,
    int additionalCount = 1,
  }) {
    return selectedCount >= 0 &&
        additionalCount >= 0 &&
        selectedCount + additionalCount <= maxDistinctItems;
  }

  static bool isWithinDistinctItemLimit(int count) {
    return count >= 0 && count <= maxDistinctItems;
  }
}
