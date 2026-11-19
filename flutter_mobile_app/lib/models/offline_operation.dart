class PendingFollowUp {
  const PendingFollowUp({
    required this.date,
    required this.status,
    this.outcomeSent = false,
  });

  final String date;
  final String status;
  final bool outcomeSent;

  PendingFollowUp get afterOutcomeSent =>
      PendingFollowUp(date: date, status: status, outcomeSent: true);

  PendingFollowUp withStatus(String next) =>
      PendingFollowUp(date: date, status: next, outcomeSent: outcomeSent);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'date': date,
    'status': status,
    'outcomeSent': outcomeSent,
  };

  static PendingFollowUp? fromJson(Object? json) {
    if (json is! Map) return null;
    final String date = _text(json['date']);
    final String status = _text(json['status']);
    if (date.isEmpty || status.isEmpty) return null;
    return PendingFollowUp(
      date: date,
      status: status,
      outcomeSent: json['outcomeSent'] == true,
    );
  }
}

class OfflineOperation {
  const OfflineOperation({
    required this.operationId,
    required this.type,
    required this.documentId,
    required this.payload,
    required this.createdAt,
    this.attempts = 0,
    this.nextRetryAt,
    this.lastError = '',
    this.targetKind = '',
    this.targetStatus = '',
    this.stopId = '',
    this.followUp,
  });

  final String operationId;
  final String type;
  final String documentId;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final int attempts;
  final DateTime? nextRetryAt;
  final String lastError;
  final String targetKind;
  final String targetStatus;
  final String stopId;
  final PendingFollowUp? followUp;

  OfflineOperation copyWith({
    int? attempts,
    DateTime? nextRetryAt,
    String? lastError,
    String? targetStatus,
    PendingFollowUp? followUp,
  }) {
    return OfflineOperation(
      operationId: operationId,
      type: type,
      documentId: documentId,
      payload: payload,
      createdAt: createdAt,
      attempts: attempts ?? this.attempts,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
      lastError: lastError ?? this.lastError,
      targetKind: targetKind,
      targetStatus: targetStatus ?? this.targetStatus,
      stopId: stopId,
      followUp: followUp ?? this.followUp,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'operationId': operationId,
    'type': type,
    'documentId': documentId,
    'payload': payload,
    'createdAt': createdAt.toIso8601String(),
    'attempts': attempts,
    if (nextRetryAt != null) 'nextRetryAt': nextRetryAt!.toIso8601String(),
    'lastError': lastError,
    'targetKind': targetKind,
    'targetStatus': targetStatus,
    'stopId': stopId,
    if (followUp != null) 'followUp': followUp!.toJson(),
  };

  factory OfflineOperation.fromJson(Map<String, dynamic> json) {
    return OfflineOperation(
      operationId: _text(json['operationId']),
      type: _text(json['type']),
      documentId: _text(json['documentId']),
      payload: Map<String, dynamic>.from(
        json['payload'] as Map? ?? const <String, dynamic>{},
      ),
      createdAt:
          DateTime.tryParse(_text(json['createdAt'])) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      nextRetryAt: DateTime.tryParse(_text(json['nextRetryAt'])),
      lastError: _text(json['lastError']),
      targetKind: _text(json['targetKind']),
      targetStatus: _text(json['targetStatus']),
      stopId: _text(json['stopId']),
      followUp: PendingFollowUp.fromJson(json['followUp']),
    );
  }
}

class OfflineQueueLedger {
  OfflineQueueLedger([Iterable<OfflineOperation> operations = const []])
    : _operations = <String, OfflineOperation>{
        for (final OfflineOperation operation in operations)
          operation.operationId: operation,
      };

  final Map<String, OfflineOperation> _operations;

  List<OfflineOperation> get ordered {
    final List<OfflineOperation> rows = _operations.values.toList()
      ..sort(
        (OfflineOperation left, OfflineOperation right) =>
            left.createdAt.compareTo(right.createdAt),
      );
    return rows;
  }

  int get length => _operations.length;

  void put(OfflineOperation operation) {
    _operations[operation.operationId] = operation;
  }

  void remove(String operationId) {
    _operations.remove(operationId);
  }

  OfflineOperation? operator [](String operationId) => _operations[operationId];
}

String _text(Object? value) => (value ?? '').toString().trim();
