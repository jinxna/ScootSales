import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../copilot/mobile_copilot_page.dart';
import '../models/guided_visit_context.dart';
import '../services/cart_draft_cache.dart';
import '../services/held_work_sync.dart';
import '../utils/quantity_unit.dart';
import 'package:scoot_design/scoot_design.dart';
import '../widgets/phone_card.dart';

enum DraftSource { count, signOff }

class DraftSavedScreen extends StatelessWidget {
  final String retailerName;
  final String retailerId;
  final String? visitId;
  final GuidedVisitContext? guidedVisitContext;
  final DraftSource source;

  final List<Map<String, dynamic>> items;

  final Set<String> signedDepartments;

  final VoidCallback onResume;

  const DraftSavedScreen({
    super.key,
    required this.retailerName,
    required this.retailerId,
    this.visitId,
    this.guidedVisitContext,
    required this.source,
    required this.items,
    this.signedDepartments = const {},
    required this.onResume,
  });

  String get _savedAt {
    final now = DateTime.now();
    final date =
        '${now.day.toString().padLeft(2, '0')}/'
        '${now.month.toString().padLeft(2, '0')}/'
        '${now.year}';
    final time =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }

  String get _totalQty =>
      totalQuantityLabel(items.map((i) => ((i['qty'] as int?) ?? 0, uomOf(i))));

  Map<String, List<Map<String, dynamic>>> get _byDepartment {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final item in items) {
      final dept = (item['department'] as String?)?.trim();
      final key = (dept == null || dept.isEmpty) ? 'Other' : dept;
      map.putIfAbsent(key, () => []).add(item);
    }
    return map;
  }

  String get _sourceLabel =>
      source == DraftSource.count ? 'Count (step 2)' : 'Sign-off (step 3)';

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return ScootPhoneScaffold(
      appBar: ScootPhoneAppBar(
        title: 'Draft saved',
        onBack: () => Navigator.of(context).popUntil((r) => r.isFirst),
        actions: const <Widget>[CopilotEntryButton()],
      ),
      body: ListView(
        padding: const EdgeInsets.all(ScootSpace.phoneGutter),
        children: <Widget>[
          Text(
            retailerName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: ScootType.h2.copyWith(color: c.ink),
          ),
          if (retailerId.isNotEmpty)
            Text(retailerId, style: ScootType.small.copyWith(color: c.muted)),
          const SizedBox(height: 12),
          const ScootNotice(
            tone: ScootTone.warning,
            icon: ScootIcons.info,
            title: 'Saved on this phone only',
            message:
                'The order is not sent. Clearing app data removes the draft. '
                'Resume it, then submit when you are ready.',
          ),
          const SizedBox(height: 12),
          PhoneCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: <Widget>[
                PhoneRow(label: 'Saved at', value: _savedAt),
                const PhoneDivider(),
                PhoneRow(label: 'Saved from', value: _sourceLabel),
                const PhoneDivider(),
                PhoneRow(
                  label: 'Products',
                  value: '${items.length} item${items.length == 1 ? '' : 's'}',
                ),
                const PhoneDivider(),
                PhoneRow(label: 'Total quantity', value: _totalQty),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _pendingInfo(c),
          const PhoneSectionTitle('Saved items'),
          if (items.isEmpty)
            PhoneCard(
              child: Text(
                'No products were saved in this draft.',
                style: ScootType.body.copyWith(color: c.text2),
              ),
            ),
          for (final MapEntry<String, List<Map<String, dynamic>>> entry
              in _byDepartment.entries) ...<Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      entry.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ScootType.smallStrong.copyWith(color: c.text2),
                    ),
                  ),
                  Text(
                    '${entry.value.length} item${entry.value.length == 1 ? '' : 's'}',
                    style: ScootType.small.copyWith(color: c.muted),
                  ),
                ],
              ),
            ),
            PhoneCard(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: <Widget>[
                  for (int i = 0; i < entry.value.length; i++) ...<Widget>[
                    if (i > 0) const PhoneDivider(),
                    _itemRow(entry.value[i], c),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          TextButton(
            onPressed: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
            child: const Text('Go to Home'),
          ),
        ],
      ),
      primaryAction: ScootPrimaryActionBar(
        label: 'Resume order',
        icon: ScootIcons.play,
        onPressed: onResume,
        secondaryLabel: 'Discard draft',
        onSecondary: () => _confirmDiscard(context),
      ),
    );
  }

  Widget _itemRow(Map<String, dynamic> item, ScootColors c) {
    final String name = (item['name'] as String?) ?? '-';
    final String packingSize = (item['packingSize'] as String?) ?? '';
    final int qty = (item['qty'] as int?) ?? 0;
    final String expiry = (item['expiry'] as String?) ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  name,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: ScootType.bodyStrong.copyWith(color: c.ink),
                ),
                if (packingSize.isNotEmpty)
                  Text(
                    packingSize,
                    style: ScootType.small.copyWith(color: c.muted),
                  ),
                if (expiry.isNotEmpty)
                  Text(
                    'Expiry: $expiry',
                    style: ScootType.small.copyWith(color: c.muted),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            quantityLabel(qty, uomOf(item)),
            style: ScootType.bodyStrong.copyWith(
              color: qty > 0 ? c.brandText : c.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pendingInfo(ScootColors c) {
    if (source == DraftSource.count) {
      return const ScootNotice(
        tone: ScootTone.info,
        icon: ScootIcons.info,
        message:
            'You were at the Count step. Quantities and shelf batch details '
            'come back when you resume.',
      );
    }
    final List<String> all = _byDepartment.keys.toList();
    final List<String> signed = all.where(signedDepartments.contains).toList();
    final List<String> unsigned = all
        .where((String d) => !signedDepartments.contains(d))
        .toList();
    if (unsigned.isEmpty && signed.isNotEmpty) {
      return const ScootNotice(
        tone: ScootTone.success,
        icon: ScootIcons.check,
        message: 'All signatures are collected. Resume to submit the order.',
      );
    }
    return PhoneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (signed.isNotEmpty) ...<Widget>[
            Text(
              'Signatures collected',
              style: ScootType.smallStrong.copyWith(color: c.success.noteText),
            ),
            for (final String dept in signed)
              Text(dept, style: ScootType.small.copyWith(color: c.text2)),
            if (unsigned.isNotEmpty) const SizedBox(height: 10),
          ],
          if (unsigned.isNotEmpty) ...<Widget>[
            Text(
              'Signatures still needed',
              style: ScootType.smallStrong.copyWith(color: c.warning.noteText),
            ),
            for (final String dept in unsigned)
              Text(dept, style: ScootType.small.copyWith(color: c.text2)),
          ],
        ],
      ),
    );
  }

  void _confirmDiscard(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Discard draft?'),
        content: const Text(
          'This will permanently delete all saved quantities, '
          'expiry dates, and remarks for this order. '
          'This action cannot be undone.',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              elevation: 0,
            ),
            onPressed: () {
              final salesmanUid =
                  FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
              final String draftKey = CartDraftCache.keyFor(
                salesmanUid: salesmanUid,
                retailerId: retailerId,
                visitId: visitId,
                routePlanId: guidedVisitContext?.planId,
                routeStopId: guidedVisitContext?.stopId,
              );
              final String pendingOrderId =
                  CartDraftCache.read(draftKey)?.pendingOrderId.trim() ?? '';
              CartDraftCache.clear(draftKey);
              if (pendingOrderId.isNotEmpty) {
                unawaited(
                  HeldWorkSync().forgetOrder(salesmanUid, pendingOrderId),
                );
              }
              final safeVisitId = visitId?.trim() ?? '';
              if (guidedVisitContext == null && safeVisitId.isNotEmpty) {
                FirebaseFirestore.instance
                    .collection('visits')
                    .doc(safeVisitId)
                    .update({
                      'progress': 0,
                      'status': 'Planned',
                      'pendingSignatures': FieldValue.delete(),
                      'draftStage': FieldValue.delete(),
                      'cartDraftItems': FieldValue.delete(),
                      'signatureDraft': FieldValue.delete(),
                      'signOffDraftAt': FieldValue.delete(),
                      'submittedOrderId': FieldValue.delete(),
                      'step1At': FieldValue.delete(),
                      'step2At': FieldValue.delete(),
                      'step3At': FieldValue.delete(),
                      'updatedAt': FieldValue.serverTimestamp(),
                    });
              }
              Navigator.of(ctx).pop();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!context.mounted) return;
                Navigator.of(context).popUntil((route) => route.isFirst);
              });
            },
            child: const Text('Discard'),
          ),
        ],
      ),
    );
  }
}
