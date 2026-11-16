import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import '../store/cc_store.dart';
import 'cc_command.dart';
import 'cc_common.dart';

Future<bool> confirmPaymentCheck(
  BuildContext context,
  CcStore store,
  StaffPaymentEntry entry,
) async {
  final bool ok = await showCcConfirm(
    context,
    title: 'Does it match the bank statement?',
    message:
        'The statement must show ${money(entry.amountMinor ?? 0)} with bank reference ${entry.externalReference ?? ''}. After you confirm, the receipt is emailed and the payment covers the whole invoice period.',
    confirmLabel: 'Matches bank statement',
  );
  if (!ok || !context.mounted) return false;
  final CmdResult result = await CmdResult.run(
    () => store.api.checkPayment(entry.tenantId, entry.entryId),
    done: 'The payment was checked.',
  );
  if (!context.mounted) return false;
  if (result.ok) {
    announce(context, result.message!);
  } else {
    announce(context, result.message ?? 'The payment could not be checked.');
  }
  await store.refreshMoney();
  return result.ok;
}

Future<bool> voidPaymentFlow(
  BuildContext context,
  CcStore store,
  StaffPaymentEntry entry,
) => showCcCommand(
  context,
  title: 'Ask to void this payment',
  confirmLabel: 'Send for approval',
  danger: true,
  reasonHint: 'Say what was wrong. Saved in the audit log.',
  body: Text(
    '${money(entry.amountMinor ?? 0)} for invoice ${entry.invoiceReference ?? ''}, bank reference ${entry.externalReference ?? ''}. It waits for approval in the Inbox. Then the invoice goes back to unpaid and the reference stays blocked. The person who recorded the payment cannot approve it, unless they are the solo owner.',
    style: Cc.small,
  ),
  run: (String reason, String key) => sendForApproval(
    store.api,
    action: 'payment.void',
    params: <String, Object?>{'receiptId': entry.entryId},
    reason: reason,
    key: key,
    tenantId: entry.tenantId,
  ),
);

class PaymentActionButtons extends StatelessWidget {
  const PaymentActionButtons({
    super.key,
    required this.store,
    required this.entry,
    required this.onDone,
    this.showCheck = true,
    this.showVoid = true,
  });

  final CcStore store;
  final StaffPaymentEntry entry;
  final VoidCallback onDone;
  final bool showCheck, showVoid;

  @override
  Widget build(BuildContext context) {
    final bool unchecked = entry.check == null;
    final bool? serverCanCheck =
        entry.canCheck ??
        store.toCheck?.value
            ?.where((StaffPaymentEntry row) => row.entryId == entry.entryId)
            .firstOrNull
            ?.canCheck;
    final bool canCheck = serverCanCheck ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          children: <Widget>[
            if (showCheck && unchecked && serverCanCheck != null)
              Semantics(
                button: true,
                enabled: canCheck,
                label:
                    'Matches bank statement, ${entry.companyName ?? store.companyName(entry.tenantId)}, ${entry.invoiceReference ?? ''}',
                excludeSemantics: true,
                onTap: canCheck
                    ? () async {
                        if (await confirmPaymentCheck(context, store, entry)) {
                          onDone();
                        }
                      }
                    : null,
                child: FilledButton(
                  onPressed: canCheck
                      ? () async {
                          if (await confirmPaymentCheck(
                            context,
                            store,
                            entry,
                          )) {
                            onDone();
                          }
                        }
                      : null,
                  child: const Text('Matches bank statement'),
                ),
              ),
            if (showVoid)
              Semantics(
                button: true,
                label:
                    'Ask to void payment ${entry.invoiceReference ?? ''}, ${entry.externalReference ?? ''}',
                excludeSemantics: true,
                onTap: () async {
                  if (await voidPaymentFlow(context, store, entry)) {
                    await store.refreshApprovals();
                    onDone();
                  }
                },
                child: OutlinedButton(
                  onPressed: () async {
                    if (await voidPaymentFlow(context, store, entry)) {
                      await store.refreshApprovals();
                      onDone();
                    }
                  },
                  child: const Text('Void…'),
                ),
              ),
          ],
        ),
        if (serverCanCheck == false &&
            showCheck &&
            unchecked &&
            entry.createdBy == store.me)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'You recorded it, so another person checks it.',
              style: Cc.small,
              textAlign: TextAlign.right,
            ),
          ),
      ],
    );
  }
}
