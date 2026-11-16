import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import 'cc_command.dart';
import 'cc_common.dart';

const List<String> _newLimitKeys = <String>[
  'salesmen',
  'supervisors',
  'admins',
  'branchManagers',
  'products',
];

String packageIdFor(String name) {
  final String id = name
      .toUpperCase()
      .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return id.length > 32 ? id.substring(0, 32) : id;
}

num? _amount(String text) {
  final String value = text.trim().replaceAll(',', '');
  return value.isEmpty ? null : num.tryParse(value);
}

String _field(num? price) => price == null ? '' : price.toString();

Future<bool> showPackageForm(
  BuildContext context,
  StaffApiClient api, {
  StaffPackage? existing,
  required Set<String> takenIds,
}) async {
  final bool isNew = existing == null;
  final List<String> keys = isNew
      ? _newLimitKeys
      : existing.limits.keys.toList(growable: false);
  final TextEditingController name = TextEditingController(
    text: existing?.name ?? '',
  );
  final Map<String, TextEditingController> limits =
      <String, TextEditingController>{
        for (final String key in keys)
          key: TextEditingController(
            text: existing?.limits[key]?.toString() ?? '',
          ),
      };
  final TextEditingController monthly = TextEditingController(
    text: _field(existing?.monthlyPrice),
  );
  final TextEditingController yearly = TextEditingController(
    text: _field(existing?.yearlyPrice),
  );
  String edition = existing?.edition ?? 'basic';
  final bool priced =
      existing != null &&
      (existing.monthlyPrice != null || existing.yearlyPrice != null);
  final bool saved = await showCcCommand(
    context,
    title: isNew ? 'Add a package' : 'Edit ${existing.name}',
    confirmLabel: isNew ? 'Add package' : 'Save package',
    body: StatefulBuilder(
      builder: (BuildContext context, StateSetter setInner) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: name,
            maxLength: 80,
            onChanged: (_) => setInner(() {}),
            decoration: const InputDecoration(labelText: 'Package name'),
          ),
          Text(
            isNew
                ? 'Package ID: ${packageIdFor(name.text).isEmpty ? '(from the name)' : packageIdFor(name.text)}'
                : 'Package ID: ${existing.planId}',
            style: Cc.small,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: edition,
            decoration: const InputDecoration(labelText: 'Edition'),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(value: 'basic', child: Text('Basic')),
              DropdownMenuItem<String>(
                value: 'advanced',
                child: Text('Advanced'),
              ),
            ],
            onChanged: (String? value) =>
                setInner(() => edition = value ?? 'basic'),
          ),
          const SizedBox(height: 16),
          const Text('Leave a limit empty for no limit.', style: Cc.small),
          for (final String key in keys) ...<Widget>[
            const SizedBox(height: 12),
            TextField(
              controller: limits[key],
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '${staffLimitLabels[key] ?? key} allowed',
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            priced
                ? 'A changed price needs approval. Approve it in Inbox.'
                : 'Leave both prices empty to price this package by quote.',
            style: Cc.small,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: monthly,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Monthly price (RM)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: yearly,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Yearly price (RM)'),
          ),
        ],
      ),
    ),
    run: (String reason, String key) async {
      final String title = name.text.trim();
      final String planId = isNew ? packageIdFor(title) : existing.planId;
      if (title.isEmpty || planId.isEmpty) {
        return const CmdResult.fail('Enter a package name.');
      }
      if (isNew && takenIds.contains(planId)) {
        return CmdResult.fail(
          'A package with the ID $planId exists. Choose another name, or edit that package.',
        );
      }
      final Map<String, int?> parsed = <String, int?>{};
      for (final String limit in keys) {
        final String text = limits[limit]!.text.trim();
        final int? value = text.isEmpty ? null : int.tryParse(text);
        if (text.isNotEmpty && (value == null || value < 0)) {
          return CmdResult.fail(
            'Enter a whole number of 0 or more for ${staffLimitLabels[limit] ?? limit}, or leave it empty for no limit.',
          );
        }
        parsed[limit] = value;
      }
      final num? month = _amount(monthly.text), year = _amount(yearly.text);
      if ((monthly.text.trim().isNotEmpty && month == null) ||
          (yearly.text.trim().isNotEmpty && year == null)) {
        return const CmdResult.fail(
          'Enter prices in RM, for example 1500, or leave them empty.',
        );
      }
      if (priced && month == null && year == null) {
        return const CmdResult.fail(
          'A priced package cannot go back to no price here. Enter at least one price.',
        );
      }
      final bool contentChanged =
          isNew ||
          title != existing.name ||
          edition != existing.edition ||
          keys.any((String limit) => parsed[limit] != existing.limits[limit]);
      final bool priceChanged = isNew
          ? month != null || year != null
          : month != existing.monthlyPrice || year != existing.yearlyPrice;
      if (!contentChanged && !priceChanged) {
        return const CmdResult.fail('Nothing was changed.');
      }
      final String done = priceChanged && priced
          ? 'Saved. The new price was sent for approval. Approve it in Inbox.'
          : isNew
          ? 'The package was added.'
          : 'The package was saved.';
      return CmdResult.run(() async {
        if (contentChanged) {
          final StaffOperationOutcome outcome = await api.savePackage(
            planId,
            isNew: isNew,
            name: title,
            edition: edition,
            limits: parsed,
            reason: reason,
            key: key,
          );
          if (!outcome.completed) {
            throw const StaffApiException(
              'The package was not saved. Try again.',
            );
          }
        }
        if (priceChanged && (month != null || year != null)) {
          if (priced) {
            await api.requestPriceChange(
              planId,
              monthly: month,
              yearly: year,
              reason: reason,
              key: '$key-price',
            );
          } else {
            await api.setFirstPrice(
              planId,
              monthly: month,
              yearly: year,
              reason: reason,
              key: '$key-price',
            );
          }
        }
        return true;
      }, done: done);
    },
  );
  name.dispose();
  monthly.dispose();
  yearly.dispose();
  for (final TextEditingController controller in limits.values) {
    controller.dispose();
  }
  return saved;
}
