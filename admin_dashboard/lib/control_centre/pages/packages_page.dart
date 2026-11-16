import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import '../store/cc_store.dart';
import '../widgets/cc_command.dart';
import '../widgets/cc_common.dart';
import '../widgets/cc_nav.dart';
import '../widgets/cc_shell.dart';
import '../widgets/company_requests.dart';
import '../widgets/package_form.dart';

class PackagesPage extends StatefulWidget {
  const PackagesPage({super.key, required this.store, required this.nav});

  final CcStore store;
  final CcNav nav;

  @override
  State<PackagesPage> createState() => _PackagesPageState();
}

class _PackagesPageState extends State<PackagesPage> {
  Loaded<List<StaffPackage>>? _packages;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _packages = null);
    final Loaded<List<StaffPackage>> loaded = await Loaded.of(
      widget.store.api.packages(),
    );
    if (mounted) setState(() => _packages = loaded);
  }

  String _price(num? price) =>
      price == null ? 'By quote' : money((price * 100).round());

  bool _unpriced(StaffPackage p) =>
      p.monthlyPrice == null && p.yearlyPrice == null;

  num? _amount(String text) {
    final String value = text.trim().replaceAll(',', '');
    return value.isEmpty ? null : num.tryParse(value);
  }

  String _field(num? price) => price == null ? '' : price.toString();

  Future<void> _editPrice(StaffPackage p) async {
    final bool first = _unpriced(p);
    final TextEditingController monthly = TextEditingController(
      text: _field(p.monthlyPrice),
    );
    final TextEditingController yearly = TextEditingController(
      text: _field(p.yearlyPrice),
    );
    final bool saved = await showCcCommand(
      context,
      title: first
          ? 'Set the first price of ${p.name}'
          : 'Change the price of ${p.name}',
      confirmLabel: first ? 'Save price' : 'Send for approval',
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            first
                ? 'This package has no price yet, so no approval is needed. A later price change needs approval.'
                : 'A price change needs approval. Approve it in Inbox. Companies keep their current price until the package is applied again.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey<String>('first-price-monthly'),
            controller: monthly,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Monthly price (RM)'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey<String>('first-price-yearly'),
            controller: yearly,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Yearly price (RM)'),
          ),
        ],
      ),
      run: (String reason, String key) async {
        final num? month = _amount(monthly.text), year = _amount(yearly.text);
        if ((monthly.text.trim().isNotEmpty && month == null) ||
            (yearly.text.trim().isNotEmpty && year == null) ||
            (month == null && year == null)) {
          return const CmdResult.fail(
            'Enter a monthly or yearly price in RM, for example 1500.',
          );
        }
        if (!first) {
          return CmdResult.run(
            () => widget.store.api.requestPriceChange(
              p.planId,
              monthly: month,
              yearly: year,
              reason: reason,
              key: key,
            ),
            done: 'Sent for approval. Approve it in Inbox.',
          );
        }
        return savedOrWaiting(
          () => widget.store.api.setFirstPrice(
            p.planId,
            monthly: month,
            yearly: year,
            reason: reason,
            key: key,
          ),
          saved: 'Price saved',
        );
      },
    );
    monthly.dispose();
    yearly.dispose();
    if (saved) await _load();
  }

  Future<void> _form({StaffPackage? existing}) async {
    final bool saved = await showPackageForm(
      context,
      widget.store.api,
      existing: existing,
      takenIds: <String>{
        for (final StaffPackage p in _packages?.value ?? const <StaffPackage>[])
          p.planId,
      },
    );
    if (saved) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final Loaded<List<StaffPackage>>? loaded = _packages;
    return CcPage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CcPageHeader(
            'Packages',
            actions: <Widget>[
              if (widget.store.profile?.isOwner ?? false)
                FilledButton.icon(
                  onPressed: loaded?.value == null ? null : () => _form(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add package'),
                ),
            ],
          ),
          if (loaded == null)
            const CcSkeleton(rows: 4)
          else if (loaded.value == null)
            CcErrorState(
              what: 'packages',
              message: loaded.error!,
              onRetry: _load,
            )
          else
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final bool compact = constraints.maxWidth < 900;
                return CcTable(
                  columns: <CcColumn>[
                    compact
                        ? const CcColumn('Package', width: 140)
                        : const CcColumn('Package', flex: 2),
                    const CcColumn('Limits', flex: 5, hideBelow: 900),
                    const CcColumn('Monthly', width: 130, right: true),
                    const CcColumn('Yearly', width: 130, right: true),
                    if (widget.store.profile?.isOwner ?? false)
                      compact
                          ? const CcColumn('', right: true)
                          : const CcColumn('', width: 330, right: true),
                  ],
                  rows: <CcTableRow>[
                    for (final StaffPackage p in loaded.value!)
                      CcTableRow(
                        cells: <Widget>[
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                p.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Cc.ink,
                                ),
                              ),
                              if (p.tagline != null)
                                Text(p.tagline!, style: Cc.small),
                            ],
                          ),
                          Text(limitsText(p.limits), style: Cc.small),
                          Text(_price(p.monthlyPrice), style: Cc.numbers),
                          Text(_price(p.yearlyPrice), style: Cc.numbers),
                          if (widget.store.profile?.isOwner ?? false)
                            Wrap(
                              alignment: WrapAlignment.end,
                              children: <Widget>[
                                TextButton(
                                  onPressed: () => _form(existing: p),
                                  child: Text('Edit ${p.name}'),
                                ),
                                TextButton(
                                  onPressed: () => _editPrice(p),
                                  child: Text(
                                    _unpriced(p)
                                        ? 'Set price for ${p.name}'
                                        : 'Change price for ${p.name}',
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                  ],
                  empty: const CcEmptyState(
                    title: 'No packages',
                    message: 'The package list is empty.',
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
