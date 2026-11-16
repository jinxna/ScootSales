import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import 'cc_command.dart';
import 'cc_common.dart';

final RegExp _dropSentence = RegExp(
  r'^(?:The )?(.+) would drop from (.+) to (.+)\.$',
);

List<String> refusalSentences(String? reason) {
  final String text = (reason ?? '').trim();
  if (text.isEmpty) return const <String>['Not available.'];
  final List<String> parts = text
      .split('. ')
      .where((String part) => part.isNotEmpty)
      .toList(growable: false);
  return <String>[
    for (int i = 0; i < parts.length; i++)
      i < parts.length - 1 ? '${parts[i]}.' : parts[i],
  ];
}

const Map<String, String> _packagePartNames = <String, String>{
  'subscription': 'subscription',
  'companyLimits': 'company limits',
  'companyRecord': 'company record',
};

String _joinNames(List<String> names) => names.length < 2
    ? names.join()
    : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';

String? packageProgressText(Map<Object?, Object?>? body) {
  final Object? parts = body?['parts'];
  if (parts is! Map) return null;
  List<String> named(String state) => <String>[
    for (final MapEntry<String, String> part in _packagePartNames.entries)
      if (parts[part.key] == state) part.value,
  ];
  final List<String> saved = named('saved');
  final List<String> pending = named('pending');
  final List<String> unknown = named('unknown');
  if (saved.isEmpty && pending.isEmpty && unknown.isEmpty) return null;
  final List<String> sentences = <String>[
    saved.isEmpty ? 'Nothing is saved yet.' : 'Saved: ${_joinNames(saved)}.',
    if (pending.isNotEmpty) 'Not finished: ${_joinNames(pending)}.',
    if (unknown.isNotEmpty) 'Could not check: ${_joinNames(unknown)}.',
  ];
  return sentences.join(' ');
}

Future<String> finishPackageMessage(
  StaffApiClient api,
  String operationId,
) async {
  try {
    final StaffOperationOutcome outcome = await api.retryOperation(operationId);
    return outcome.completed
        ? 'Package finished.'
        : 'The package is still not finished. Open Activity on the company page.';
  } on StaffApiException catch (error) {
    return '${packageProgressText(error.body) ?? ''} ${friendlyError(error)}'
        .trim();
  }
}

Widget refusalLine(String sentence) {
  final RegExpMatch? drop = _dropSentence.firstMatch(sentence);
  if (drop == null) return Text(sentence, style: Cc.small);
  final String label = drop[1]!;
  return Text(
    '${label[0].toUpperCase()}${label.substring(1)}: ${drop[2]} → ${drop[3]}',
    semanticsLabel: sentence,
    style: Cc.small,
  );
}

Future<bool> showPackageChange(
  BuildContext context,
  StaffApiClient api,
  StaffCompany company,
  StaffCompanyPackages packages, {
  String? planId,
  String? interval,
  VoidCallback? onPrepare,
  Future<void> Function()? onFinished,
}) {
  final List<StaffPackage> allowed = packages.packages
      .where((StaffPackage p) => p.canRequest == true)
      .toList(growable: false);
  final List<StaffPackage> refused = packages.packages
      .where((StaffPackage p) => p.canRequest != true)
      .toList(growable: false);
  String? chosen = allowed.any((StaffPackage p) => p.planId == planId)
      ? planId
      : null;
  String billing = interval ?? packages.current?.billingInterval ?? 'monthly';
  final StaffCurrentPackage? current = packages.current;
  Future<void> finishPackage(String operationId) async {
    final String message = await finishPackageMessage(api, operationId);
    if (onFinished != null) await onFinished();
    if (context.mounted) announce(context, message);
  }

  CmdFix finishFix(String operationId) =>
      CmdFix('Finish package', () => finishPackage(operationId));

  return showCcCommand(
    context,
    title: 'Change package',
    confirmLabel: 'Apply package',
    body: StatefulBuilder(
      builder: (BuildContext context, StateSetter setInner) {
        final StaffPackage? selected = allowed
            .where((StaffPackage p) => p.planId == chosen)
            .firstOrNull;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              current == null
                  ? 'No package yet.'
                  : 'Current package: ${current.name} (${current.planId}), ${current.billingInterval == null ? 'no billing period' : intervalLabel(current.billingInterval)}',
            ),
            const SizedBox(height: 14),
            if (allowed.isEmpty)
              const CcBanner(
                text:
                    'No packages are available. Packages can only move up in this release.',
              )
            else
              DropdownButtonFormField<String>(
                initialValue: chosen,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Package'),
                items: <DropdownMenuItem<String>>[
                  for (final StaffPackage p in allowed)
                    DropdownMenuItem<String>(
                      value: p.planId,
                      child: Text('${p.name} (${p.planId})'),
                    ),
                ],
                onChanged: (String? value) => setInner(() => chosen = value),
              ),
            if (selected != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(limitsText(selected.limits), style: Cc.small),
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: billing,
              decoration: const InputDecoration(labelText: 'Billing period'),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem<String>(
                  value: 'monthly',
                  child: Text('Monthly'),
                ),
                DropdownMenuItem<String>(
                  value: 'yearly',
                  child: Text('Yearly'),
                ),
              ],
              onChanged: (String? value) =>
                  setInner(() => billing = value ?? 'monthly'),
            ),
            if (refused.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              const Text(
                'Not available for this company:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final StaffPackage p in refused) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  '${p.name} (${p.planId})',
                  style: Cc.small.copyWith(fontWeight: FontWeight.w600),
                ),
                for (final String sentence in refusalSentences(p.requestReason))
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 2),
                    child: refusalLine(sentence),
                  ),
              ],
            ],
          ],
        );
      },
    ),
    run: (String reason, String key) async {
      if (chosen == null) return const CmdResult.fail('Choose a package.');
      if (reason.length < 3) {
        return const CmdResult.fail('Enter a reason of at least 3 characters.');
      }
      try {
        final StaffOperationOutcome outcome = await api
            .changePackage(company.tenantId, <String, Object?>{
              'planId': chosen,
              'billingInterval': billing,
              'expectedRevision': current?.revision ?? 0,
              'reason': reason,
            }, key: key);
        if (outcome.completed) return const CmdResult.ok('Package changed.');
        if (outcome.status == 'failed') {
          return CmdResult.fail(
            'The package change did not finish. Some parts may already be saved.',
            fix: finishFix(outcome.operationId),
          );
        }
        return const CmdResult.fail(
          'The company update is not confirmed yet. Open Activity on the company page and press Retry.',
        );
      } on StaffApiException catch (error) {
        final bool needsPrepare = error.fix == 'prepare_data';
        final String? progress = isUncertain(error)
            ? null
            : packageProgressText(error.body);
        final Object? failedOperation = error.body?['operationId'];
        final CmdFix? finish =
            progress != null &&
                failedOperation is String &&
                error.body?['status'] == 'failed'
            ? finishFix(failedOperation)
            : null;
        return CmdResult.fail(
          isUncertain(error)
              ? uncertainMessage
              : progress != null
              ? '$progress ${friendlyError(error)}'
              : needsPrepare && onPrepare == null
              ? '${friendlyError(error)} Ask the owner to press Prepare company data on this company page, then try again.'
              : friendlyError(error),
          uncertain: isUncertain(error),
          fix:
              finish ??
              (needsPrepare && onPrepare != null
                  ? CmdFix('Prepare company data first', onPrepare)
                  : null),
        );
      }
    },
  );
}
