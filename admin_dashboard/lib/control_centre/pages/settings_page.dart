import 'package:flutter/material.dart';

import '../store/cc_store.dart';
import '../widgets/cc_common.dart';
import '../widgets/cc_shell.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.store});

  final CcStore store;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Future<List<String>> _actions = widget.store.api.approvalActions();

  String _approvalText(AsyncSnapshot<List<String>> snapshot) {
    final List<String>? actions = snapshot.data;
    if (actions == null) {
      return snapshot.hasError
          ? 'The list could not be loaded. Reload the page to try again.'
          : 'Loading the list.';
    }
    final String listed = actions.length < 2
        ? actions.join()
        : '${actions.sublist(0, actions.length - 1).join(', ')} and ${actions.last}';
    return 'These need approval by a second owner or operator, or by the solo owner: $listed.';
  }

  @override
  Widget build(BuildContext context) => CcPage(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const CcPageHeader('Settings'),
        CcCard(
          title: 'Billing rules',
          child: CcKeyValue(<(String, Widget)>[
            (
              'Currency',
              const Text(
                'Malaysian ringgit (RM). Times are shown in Kuala Lumpur time.',
              ),
            ),
            (
              'Payment cover',
              const Text(
                'A new payment covers 7 days. After it is checked against the bank statement, it covers the whole invoice period.',
              ),
            ),
            (
              'Draft invoices',
              const Text('Created 14 days before the paid-to date.'),
            ),
            (
              'Renewal reminders',
              const Text('Sent 14 days and 3 days before the paid-to date.'),
            ),
            (
              'Past due',
              const Text(
                'Set automatically 14 days after an invoice is delivered. Suspending is always a person\'s decision.',
              ),
            ),
            (
              'Extensions',
              const Text('One extension of up to 14 days for each invoice.'),
            ),
            (
              'Approvals',
              FutureBuilder<List<String>>(
                future: _actions,
                builder:
                    (
                      BuildContext context,
                      AsyncSnapshot<List<String>> snapshot,
                    ) => Text(_approvalText(snapshot)),
              ),
            ),
          ], labelWidth: 170),
        ),
        const SizedBox(height: 16),
        const CcBanner(
          tone: Tone.info,
          text:
              'These rules are fixed in the service. Ask the engineer to change one.',
        ),
      ],
    ),
  );
}
