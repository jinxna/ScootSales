import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import 'cc_command.dart';
import 'cc_common.dart';

const Map<String, String> _overridePools = <String, String>{
  'salesmen': 'Salespeople',
  'supervisors': 'Supervisors',
  'branchManagers': 'Branch managers',
  'admins': 'Admins',
  'products': 'Products',
};

const Map<String, String> _serviceLabels = <String, String>{
  'forecastingUrl': 'Forecasting address',
  'copilotUrl': 'Scout address',
};

const List<String> _editableRecordFields = <String>[
  'tenantId',
  'workspace',
  'legalName',
  'companyCode',
  'location',
  'locationKind',
  'clientConfig',
  'status',
  'planRef',
  'releaseRing',
  'rulesVersion',
  'services',
  'edition',
];

String signedTimestamp(DateTime moment) {
  final DateTime utc = moment.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}'
      'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
}

Future<bool> showQuoteRequest(
  BuildContext context,
  StaffApiClient api,
  StaffCompany company,
) {
  final TextEditingController amount = TextEditingController();
  String interval = 'monthly';
  return showCcCommand(
    context,
    title: 'Request a quoted price',
    confirmLabel: 'Send for approval',
    reasonHint: 'Why this price was agreed. Saved in the audit log.',
    body: StatefulBuilder(
      builder: (BuildContext context, StateSetter setInner) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'For a company whose package is priced by quote. The quote applies to ${company.legalName}. It waits for approval in the Inbox.',
            style: Cc.small,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Price per billing period (RM)',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: interval,
            decoration: const InputDecoration(labelText: 'Billing period'),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(
                value: 'monthly',
                child: Text('Monthly'),
              ),
              DropdownMenuItem<String>(value: 'yearly', child: Text('Yearly')),
            ],
            onChanged: (String? value) =>
                setInner(() => interval = value ?? 'monthly'),
          ),
        ],
      ),
    ),
    run: (String reason, String key) {
      final RegExpMatch? price = RegExp(
        r'^(\d{1,7})(?:\.(\d{1,2}))?$',
      ).firstMatch(amount.text.trim().replaceAll(',', ''));
      final int sen = price == null
          ? 0
          : int.parse(price.group(1)!) * 100 +
                int.parse((price.group(2) ?? '0').padRight(2, '0'));
      if (sen <= 0 || sen > 100000000) {
        return Future<CmdResult>.value(
          const CmdResult.fail(
            'Enter the price in RM with at most 2 decimals, '
            'for example 250 or 250.50, above 0 and up to 1,000,000.',
          ),
        );
      }
      return sendForApproval(
        api,
        action: 'quote.price',
        params: <String, Object?>{
          'amountMinor': sen,
          'billingInterval': interval,
        },
        reason: reason,
        key: key,
        tenantId: company.tenantId,
      );
    },
  );
}

Future<bool> showOverrideRequest(
  BuildContext context,
  StaffApiClient api,
  StaffCompany company,
) {
  final Map<String, TextEditingController> fields =
      <String, TextEditingController>{
        for (final String pool in _overridePools.keys)
          pool: TextEditingController(),
      };
  final TextEditingController days = TextEditingController(text: '30');
  return showCcCommand(
    context,
    title: 'Request a package override',
    confirmLabel: 'Send for approval',
    reasonHint:
        'Why the company needs more for a while. Saved in the audit log.',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text(
          'Raise limits for a short time. Leave a limit empty to keep it as it is. The override ends by itself. It waits for approval in the Inbox.',
          style: Cc.small,
        ),
        for (final MapEntry<String, String> pool
            in _overridePools.entries) ...<Widget>[
          const SizedBox(height: 12),
          TextField(
            controller: fields[pool.key],
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: '${pool.value} limit'),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: days,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Days until it ends (1 to 180)',
          ),
        ),
      ],
    ),
    run: (String reason, String key) {
      final Map<String, Object?> limits = <String, Object?>{};
      for (final MapEntry<String, TextEditingController> field
          in fields.entries) {
        final String text = field.value.text.trim();
        if (text.isEmpty) continue;
        final int? value = int.tryParse(text);
        if (value == null || value < 0) {
          return Future<CmdResult>.value(
            CmdResult.fail(
              '${_overridePools[field.key]} limit must be a whole number, 0 or more.',
            ),
          );
        }
        limits[field.key] = value;
      }
      if (limits.isEmpty) {
        return Future<CmdResult>.value(
          const CmdResult.fail('Enter at least one limit to raise.'),
        );
      }
      final int? lasting = int.tryParse(days.text.trim());
      if (lasting == null || lasting < 1 || lasting > 180) {
        return Future<CmdResult>.value(
          const CmdResult.fail('The override must end in 1 to 180 days.'),
        );
      }
      return sendForApproval(
        api,
        action: 'plan.override',
        params: <String, Object?>{
          'limits': limits,
          'expiresAt': signedTimestamp(
            DateTime.now().toUtc().add(Duration(days: lasting)),
          ),
        },
        reason: reason,
        key: key,
        tenantId: company.tenantId,
      );
    },
  );
}

Future<CmdResult> savedOrWaiting(
  Future<StaffOperationOutcome> Function() save, {
  String saved = 'The company record was saved.',
}) async {
  StaffOperationOutcome? outcome;
  final CmdResult result = await CmdResult.run(() async {
    outcome = await save();
    return outcome;
  });
  if (!result.ok) return result;
  if (outcome != null && outcome!.completed) {
    return CmdResult.ok(saved);
  }
  if (outcome != null && outcome!.status == 'failed') {
    return const CmdResult.fail(
      'The change failed. Open Activity on the company page for the reason.',
    );
  }
  return const CmdResult.ok(
    'Request sent. It is not confirmed yet. An owner or operator can open Activity on the company page and press Retry.',
  );
}

Future<bool> showCompanyEdit(
  BuildContext context,
  StaffApiClient api,
  StaffCompany company, {
  required bool canRename,
}) {
  final Object? currentServices = company.record['services'];
  final Map<String, Object?> services = currentServices is Map
      ? Map<String, Object?>.from(currentServices)
      : <String, Object?>{};
  final TextEditingController name = TextEditingController(
    text: company.legalName,
  );
  final Map<String, TextEditingController> addresses =
      <String, TextEditingController>{
        for (final String service in _serviceLabels.keys)
          service: TextEditingController(text: '${services[service] ?? ''}'),
      };
  final String? currentRules = company.currentRulesVersion;
  final bool offerRulesUpdate =
      currentRules != null && currentRules != company.rulesVersion;
  final ValueNotifier<bool> useCurrentRules = ValueNotifier<bool>(false);
  return showCcCommand(
    context,
    title: 'Edit company record',
    confirmLabel: 'Save changes',
    reasonHint: 'What changed and why. Saved in the audit log.',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          canRename
              ? 'Only the owner changes the company name. An engineer changes service addresses. Status and package change on their own flows. Addresses must be on scootsales.my.'
              : 'An engineer changes service addresses. Only the owner changes the company name. Addresses must be on scootsales.my.',
          style: Cc.small,
        ),
        const SizedBox(height: 12),
        if (canRename)
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Company name'),
          )
        else
          Text(
            company.legalName,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        for (final MapEntry<String, String> service
            in _serviceLabels.entries) ...<Widget>[
          const SizedBox(height: 12),
          TextField(
            controller: addresses[service.key],
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: service.value,
              hintText: 'https://…',
            ),
          ),
        ],
        if (offerRulesUpdate)
          ValueListenableBuilder<bool>(
            valueListenable: useCurrentRules,
            builder: (BuildContext context, bool ticked, Widget? _) =>
                CheckboxListTile(
                  value: ticked,
                  onChanged: (bool? value) =>
                      useCurrentRules.value = value ?? false,
                  activeColor: Cc.accent,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    'Set rules version to the current build ($currentRules)',
                  ),
                  subtitle: Text(
                    'Recorded now: ${company.rulesVersion ?? 'not set'}',
                    style: Cc.small,
                  ),
                ),
          ),
      ],
    ),
    run: (String reason, String key) {
      final Object? version = company.record['version'];
      if (version is! int) {
        return Future<CmdResult>.value(
          const CmdResult.fail(
            'The company record version is missing. Reload the page and try again.',
          ),
        );
      }
      final String legalName = name.text.trim();
      if (legalName.isEmpty) {
        return Future<CmdResult>.value(
          const CmdResult.fail('Enter the company name.'),
        );
      }
      final Map<String, Object?> record = <String, Object?>{
        for (final String field in _editableRecordFields)
          if (company.record.containsKey(field)) field: company.record[field],
        'legalName': legalName,
      };
      final Map<String, Object?> nextServices = <String, Object?>{...services};
      for (final MapEntry<String, TextEditingController> address
          in addresses.entries) {
        final String text = address.value.text.trim();
        if (text.isEmpty) {
          nextServices.remove(address.key);
        } else {
          nextServices[address.key] = text;
        }
      }
      record['services'] = nextServices;
      if (offerRulesUpdate && useCurrentRules.value) {
        record['rulesVersion'] = currentRules;
      }
      return savedOrWaiting(
        () => api.putCompany(
          company.tenantId,
          record: record,
          expectedVersion: version,
          reason: reason,
          key: key,
        ),
      );
    },
  );
}
