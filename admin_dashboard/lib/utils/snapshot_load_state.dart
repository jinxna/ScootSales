enum SnapshotLoadState { loading, error, ready }

SnapshotLoadState snapshotLoadState({
  required bool isWaiting,
  required bool hasData,
  required bool hasError,
}) {
  if (hasError) return SnapshotLoadState.error;
  if (isWaiting && !hasData) return SnapshotLoadState.loading;
  return SnapshotLoadState.ready;
}
