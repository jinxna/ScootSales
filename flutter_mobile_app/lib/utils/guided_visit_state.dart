enum GuidedVisitStage { prepare, sell, close }

class GuidedVisitGate {
  const GuidedVisitGate({
    required this.stage,
    required this.canAdvance,
    required this.actionLabel,
    required this.blockedReason,
  });

  final GuidedVisitStage stage;
  final bool canAdvance;
  final String actionLabel;
  final String blockedReason;
}

GuidedVisitGate guidedVisitGate({
  required GuidedVisitStage stage,
  required String stopStatus,
  required bool orderSubmitted,
  bool orderPending = false,
  bool orderRecoveryBlocked = false,
  bool completionPending = false,
  required bool outcomeRecorded,
  required bool hasDraft,
}) {
  final String status = stopStatus.trim().toLowerCase();
  final bool hasOrder = orderSubmitted || orderPending;
  switch (stage) {
    case GuidedVisitStage.prepare:
      return GuidedVisitGate(
        stage: stage,
        canAdvance: status == 'arrived',
        actionLabel: status == 'arrived' ? 'Continue to sell' : 'Mark arrived',
        blockedReason: '',
      );
    case GuidedVisitStage.sell:
      return GuidedVisitGate(
        stage: stage,
        canAdvance: !orderRecoveryBlocked && (hasOrder || outcomeRecorded),
        actionLabel: orderRecoveryBlocked
            ? 'Order review required'
            : hasOrder || outcomeRecorded
            ? 'Continue to close'
            : hasDraft
            ? 'Resume order'
            : 'Start order',
        blockedReason: orderRecoveryBlocked
            ? 'Existing order data for this stop does not match the retailer. Ask a manager to review it.'
            : hasOrder || outcomeRecorded
            ? ''
            : 'Submit an order or record a no-order outcome before closing.',
      );
    case GuidedVisitStage.close:
      final bool ready =
          !completionPending &&
          !orderRecoveryBlocked &&
          status == 'arrived' &&
          (hasOrder || outcomeRecorded);
      return GuidedVisitGate(
        stage: stage,
        canAdvance: ready,
        actionLabel: completionPending
            ? 'Completion pending sync'
            : 'Complete stop',
        blockedReason: ready
            ? ''
            : completionPending
            ? 'Completion is saved on this device and will finish when sync is acknowledged.'
            : status != 'arrived'
            ? 'Mark the stop arrived first.'
            : orderRecoveryBlocked
            ? 'Existing order data requires manager review.'
            : 'Submit an order or record an outcome first.',
      );
  }
}
