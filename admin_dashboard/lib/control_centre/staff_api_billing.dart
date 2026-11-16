part of 'staff_api_client.dart';

String? _looseText(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  return value is String && value.trim().isNotEmpty ? value : null;
}

int _looseInt(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  return value is int ? value : 0;
}

class StaffPaymentCheck {
  const StaffPaymentCheck({
    required this.receiptNumber,
    required this.checkedBy,
    required this.checkedAt,
  });

  factory StaffPaymentCheck.fromJson(Map<String, Object?> json) =>
      StaffPaymentCheck(
        receiptNumber: _requiredText(json, 'receiptNumber'),
        checkedBy: _requiredText(json, 'checkedBy'),
        checkedAt: _requiredText(json, 'checkedAt'),
      );

  final String receiptNumber, checkedBy, checkedAt;
}

class StaffPaymentEntry {
  const StaffPaymentEntry({
    required this.entryId,
    required this.tenantId,
    required this.type,
    required this.revision,
    required this.reason,
    required this.createdBy,
    required this.createdAt,
    this.amountMinor,
    this.externalReference,
    this.invoiceId,
    this.invoiceReference,
    this.receivedAt,
    this.periodStart,
    this.periodEnd,
    this.receiptId,
    this.check,
    this.companyName,
    this.canCheck,
  });

  factory StaffPaymentEntry.fromJson(Map<String, Object?> json) {
    final String type = _requiredText(json, 'type');
    if (type != 'payment' && type != 'void') {
      throw const FormatException('Invalid payment type.');
    }
    final Object? check = json['check'];
    return StaffPaymentEntry(
      entryId: _requiredText(json, 'entryId'),
      tenantId: _requiredText(json, 'tenantId'),
      type: type,
      revision: _looseInt(json, 'revision'),
      reason: _requiredText(json, 'reason'),
      createdBy: _requiredText(json, 'createdBy'),
      createdAt: _requiredText(json, 'createdAt'),
      amountMinor: type == 'payment'
          ? _requiredInt(json, 'amountMinor', minimum: 1)
          : null,
      externalReference: _looseText(json, 'externalReference'),
      invoiceId: _looseText(json, 'invoiceId'),
      invoiceReference: _looseText(json, 'invoiceReference'),
      receivedAt: _looseText(json, 'receivedAt'),
      periodStart: _looseText(json, 'periodStart'),
      periodEnd: _looseText(json, 'periodEnd'),
      receiptId: _looseText(json, 'receiptId'),
      check: check is Map
          ? StaffPaymentCheck.fromJson(_objectMap(check))
          : null,
      companyName: _looseText(json, 'companyName'),
      canCheck: json['canCheck'] is bool ? json['canCheck']! as bool : null,
    );
  }

  final String entryId, tenantId, type, reason, createdBy, createdAt;
  final int revision;
  final int? amountMinor;
  final String? externalReference, invoiceId, invoiceReference, receivedAt;
  final String? periodStart, periodEnd, receiptId, companyName;
  final StaffPaymentCheck? check;
  final bool? canCheck;
  bool get isPayment => type == 'payment';
}

class StaffPayments {
  const StaffPayments({
    required this.entries,
    this.coveringEntryIds = const <String>[],
    this.checkedCoveringEntryIds = const <String>[],
    this.checkBy,
  });

  factory StaffPayments.fromJson(Map<String, Object?> json) {
    final Object? rows = json['entries'];
    if (rows is! List) throw const FormatException('Invalid payments.');
    final Object? cover = json['cover'];
    final Map<String, Object?> coverMap = cover is Map
        ? _objectMap(cover)
        : const <String, Object?>{};
    final Object? ids = coverMap['coveringEntryIds'];
    final Object? checkedIds = coverMap['checkedCoveringEntryIds'];
    return StaffPayments(
      entries: rows
          .map((Object? row) => StaffPaymentEntry.fromJson(_objectMap(row)))
          .toList(growable: false),
      coveringEntryIds: ids is List
          ? ids.whereType<String>().toList(growable: false)
          : const <String>[],
      checkedCoveringEntryIds: checkedIds is List
          ? checkedIds.whereType<String>().toList(growable: false)
          : const <String>[],
      checkBy: _looseText(coverMap, 'checkBy'),
    );
  }

  final List<StaffPaymentEntry> entries;
  final List<String> coveringEntryIds;
  final List<String> checkedCoveringEntryIds;
  final String? checkBy;

  Set<String> get voidedIds => <String>{
    for (final StaffPaymentEntry entry in entries)
      if (entry.type == 'void' && entry.receiptId != null) entry.receiptId!,
  };
}

class StaffCreditNote {
  const StaffCreditNote({
    required this.creditNoteId,
    required this.number,
    required this.invoiceId,
    required this.invoiceNumber,
    required this.tenantId,
    required this.amountMinor,
    required this.reason,
    required this.issuedAt,
    required this.createdBy,
  });

  factory StaffCreditNote.fromJson(Map<String, Object?> json) =>
      StaffCreditNote(
        creditNoteId: _requiredText(json, 'creditNoteId'),
        number: _requiredText(json, 'number'),
        invoiceId: _requiredText(json, 'invoiceId'),
        invoiceNumber: _looseText(json, 'invoiceNumber') ?? '',
        tenantId: _requiredText(json, 'tenantId'),
        amountMinor: _requiredInt(json, 'amountMinor', minimum: 1),
        reason: _looseText(json, 'reason') ?? '',
        issuedAt: _requiredText(json, 'issuedAt'),
        createdBy: _looseText(json, 'createdBy') ?? '',
      );

  final String creditNoteId, number, invoiceId, invoiceNumber, tenantId;
  final String reason, issuedAt, createdBy;
  final int amountMinor;
}

class StaffInvoice {
  const StaffInvoice({
    required this.invoiceId,
    required this.tenantId,
    required this.packageName,
    required this.billingInterval,
    required this.periodStart,
    required this.periodEnd,
    required this.amountMinor,
    required this.status,
    required this.note,
    required this.createdBy,
    required this.createdAt,
    required this.paidMinor,
    required this.creditedMinor,
    required this.outstandingMinor,
    this.number,
    this.issuedAt,
    this.deliveredAt,
    this.dueAt,
    this.pendingEntryId,
    this.canExtend = false,
    this.issuedBy,
    this.sentBy,
    this.source,
    this.deliveryState,
    this.deliveryReason,
    this.deliveryNeedsConfirm = false,
    this.creditNotes = const <StaffCreditNote>[],
  });

  factory StaffInvoice.fromJson(Map<String, Object?> json) {
    final String status = _requiredText(json, 'status');
    final Object? notes = json['creditNotes'];
    return StaffInvoice(
      invoiceId: _requiredText(json, 'invoiceId'),
      tenantId: _requiredText(json, 'tenantId'),
      packageName: _looseText(json, 'packageName') ?? 'Package',
      billingInterval: _looseText(json, 'billingInterval') ?? 'monthly',
      periodStart: _requiredText(json, 'periodStart'),
      periodEnd: _requiredText(json, 'periodEnd'),
      amountMinor: _requiredInt(json, 'amountMinor', minimum: 0),
      status: status,
      note: _looseText(json, 'note') ?? '',
      createdBy: _looseText(json, 'createdBy') ?? '',
      createdAt: _requiredText(json, 'createdAt'),
      paidMinor: _looseInt(json, 'paidMinor'),
      creditedMinor: _looseInt(json, 'creditedMinor'),
      outstandingMinor: json['outstandingMinor'] is int
          ? json['outstandingMinor']! as int
          : _requiredInt(json, 'amountMinor', minimum: 0) -
                _looseInt(json, 'paidMinor') -
                _looseInt(json, 'creditedMinor'),
      number: _looseText(json, 'number'),
      issuedAt: _looseText(json, 'issuedAt'),
      deliveredAt: _looseText(json, 'deliveredAt'),
      dueAt: _looseText(json, 'dueAt'),
      pendingEntryId: _looseText(json, 'pendingEntryId'),
      canExtend: json['canExtend'] == true,
      issuedBy: _looseText(json, 'issuedBy'),
      sentBy: _looseText(json, 'sentBy'),
      source: _looseText(json, 'source'),
      deliveryState: json['delivery'] is Map
          ? _looseText(_objectMap(json['delivery']), 'state')
          : null,
      deliveryReason: json['delivery'] is Map
          ? _looseText(_objectMap(json['delivery']), 'reason')
          : null,
      deliveryNeedsConfirm:
          json['delivery'] is Map &&
          _objectMap(json['delivery'])['needsConfirm'] == true,
      creditNotes: notes is List
          ? notes
                .map((Object? row) => StaffCreditNote.fromJson(_objectMap(row)))
                .toList(growable: false)
          : const <StaffCreditNote>[],
    );
  }

  final String invoiceId, tenantId, packageName, billingInterval, status;
  final String periodStart, periodEnd, note, createdBy, createdAt;
  final int amountMinor, paidMinor, creditedMinor, outstandingMinor;
  final String? number, issuedAt, deliveredAt, dueAt, pendingEntryId;
  final bool canExtend;
  final String? issuedBy, sentBy, source, deliveryState, deliveryReason;
  final bool deliveryNeedsConfirm;
  final List<StaffCreditNote> creditNotes;

  bool get isDraft => status == 'draft';
  bool get isVoid => status == 'void';
  bool get isPaid => status == 'paid';
  bool get isSending => deliveryState == 'sending';
  bool get isNotDelivered => deliveryState == 'not_delivered';
  bool get isOpen => status == 'issued' || status == 'sent';
  bool get canTakePayment =>
      isOpen && outstandingMinor > 0 && pendingEntryId == null;

  bool isOverdue(DateTime now) {
    final DateTime? due = dueAt == null ? null : DateTime.tryParse(dueAt!);
    return isOpen && outstandingMinor > 0 && due != null && due.isBefore(now);
  }
}

extension StaffBillingApi on StaffApiClient {
  Future<StaffPayments> payments(String tenantId) async =>
      StaffPayments.fromJson(
        _objectMap(
          await _send('GET', _uri(<String>['companies', tenantId, 'payments'])),
        ),
      );

  Future<List<StaffPaymentEntry>> paymentsToCheck() async {
    final Object? rows = _objectMap(
      await _send('GET', _uri(<String>['payments', 'to-check'])),
    )['payments'];
    if (rows is! List) throw const FormatException('Invalid payments.');
    return rows
        .map((Object? row) => StaffPaymentEntry.fromJson(_objectMap(row)))
        .toList(growable: false);
  }

  Future<StaffPaymentEntry> recordPayment(
    String tenantId,
    Map<String, Object?> body, {
    required String key,
  }) async => StaffPaymentEntry.fromJson(
    _objectMap(
      await _send(
        'POST',
        _uri(<String>['companies', tenantId, 'payments']),
        body: body,
        key: key,
      ),
    ),
  );

  Future<void> checkPayment(String tenantId, String entryId) async {
    await _send(
      'POST',
      _uri(<String>['companies', tenantId, 'payments', entryId, 'check']),
    );
  }

  Future<List<StaffInvoice>> invoices({String? tenantId}) async {
    final Uri base = _uri(<String>['invoices']);
    final Object? rows = _objectMap(
      await _send(
        'GET',
        tenantId == null
            ? base
            : base.replace(
                queryParameters: <String, String>{'tenantId': tenantId},
              ),
      ),
    )['invoices'];
    if (rows is! List) throw const FormatException('Invalid invoices.');
    return rows
        .map((Object? row) => StaffInvoice.fromJson(_objectMap(row)))
        .toList(growable: false);
  }

  Future<StaffInvoice> invoice(String invoiceId) async => StaffInvoice.fromJson(
    _objectMap(await _send('GET', _uri(<String>['invoices', invoiceId]))),
  );

  Future<StaffInvoice> createInvoiceDraft(
    String tenantId,
    Map<String, Object?> body, {
    required String key,
  }) async => StaffInvoice.fromJson(
    _objectMap(
      await _send(
        'POST',
        _uri(<String>['companies', tenantId, 'invoices']),
        body: body,
        key: key,
      ),
    ),
  );

  Future<StaffInvoice> editInvoiceDraft(
    String invoiceId,
    Map<String, Object?> body,
  ) async => StaffInvoice.fromJson(
    _objectMap(
      await _send('PATCH', _uri(<String>['invoices', invoiceId]), body: body),
    ),
  );

  Future<StaffInvoice> _invoiceAction(
    String invoiceId,
    String action, {
    Map<String, Object?>? body,
  }) async => StaffInvoice.fromJson(
    _objectMap(
      await _send(
        'POST',
        _uri(<String>['invoices', invoiceId, action]),
        body: body,
      ),
    ),
  );

  Future<StaffInvoice> issueInvoice(String invoiceId) =>
      _invoiceAction(invoiceId, 'issue');

  Future<StaffInvoice> sendInvoice(
    String invoiceId, {
    bool confirmDuplicateRisk = false,
  }) => _invoiceAction(
    invoiceId,
    'send',
    body: confirmDuplicateRisk
        ? <String, Object?>{'confirmDuplicateRisk': true}
        : null,
  );

  Future<StaffInvoice> deleteInvoiceDraft(String invoiceId) =>
      _invoiceAction(invoiceId, 'void');
}
