import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RejectedOrderBanner extends StatefulWidget {
  const RejectedOrderBanner({super.key, this.onTap});

  final VoidCallback? onTap;

  static String _prefsKey(String uid) => 'order_history_last_seen_ms_$uid';

  static final ValueNotifier<int> seenRevision = ValueNotifier<int>(0);

  static Future<void> markSeen() async {
    try {
      final String uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isEmpty) return;
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsKey(uid), DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
    seenRevision.value++;
  }

  @override
  State<RejectedOrderBanner> createState() => _RejectedOrderBannerState();
}

class _RejectedOrderBannerState extends State<RejectedOrderBanner> {
  DateTime? _lastSeen;
  bool _ready = false;
  Stream<QuerySnapshot<Map<String, dynamic>>>? _stream;

  @override
  void initState() {
    super.initState();
    _stream = rejectedOrderStream();
    RejectedOrderBanner.seenRevision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    RejectedOrderBanner.seenRevision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final DateTime? seen = await rejectedOrdersLastSeen();
    if (!mounted) return;
    setState(() {
      _lastSeen = seen;
      _ready = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Stream<QuerySnapshot<Map<String, dynamic>>>? stream = _stream;
    if (!_ready || stream == null) return const SizedBox.shrink();
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snapshot) {
        final ScootActionBannerData? data = rejectedOrderBannerData(
          snapshot.data?.docs ?? const [],
          _lastSeen,
          widget.onTap,
        );
        if (data == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: ScootActionBanner(data: data),
        );
      },
    );
  }
}

Stream<QuerySnapshot<Map<String, dynamic>>>? rejectedOrderStream() {
  final String uid = FirebaseAuth.instance.currentUser?.uid ?? '';
  if (uid.isEmpty) return null;
  return FirebaseFirestore.instance
      .collection('orders')
      .where('salesmanUid', isEqualTo: uid)
      .where('status', isEqualTo: 'rejected')
      .snapshots();
}

Future<DateTime?> rejectedOrdersLastSeen() async {
  int? ms;
  try {
    final String uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return null;
    ms = (await SharedPreferences.getInstance()).getInt(
      RejectedOrderBanner._prefsKey(uid),
    );
  } catch (_) {}
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}

ScootActionBannerData? rejectedOrderBannerData(
  Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  DateTime? lastSeen,
  VoidCallback? onTap,
) {
  final List<Map<String, dynamic>> fresh = <Map<String, dynamic>>[];
  for (final doc in docs) {
    final Map<String, dynamic> data = doc.data();
    final Object? at = data['rejectedAt'];
    final DateTime? when = at is Timestamp ? at.toDate() : null;
    if (when == null) continue;
    if (lastSeen != null && !when.isAfter(lastSeen)) continue;
    fresh.add(<String, dynamic>{...data, '_id': doc.id, '_when': when});
  }
  if (fresh.isEmpty) return null;
  fresh.sort(
    (a, b) => (b['_when'] as DateTime).compareTo(a['_when'] as DateTime),
  );
  final Map<String, dynamic> first = fresh.first;
  return ScootActionBannerData(
    priority: ScootBannerPriority.rejectedOrder,
    title: fresh.length == 1
        ? '1 order was rejected'
        : '${fresh.length} orders were rejected',
    message:
        '${first['retailerName'] ?? first['outlet'] ?? first['_id']}'
        '. ${_rejectionReason(first)}.',
    actionLabel: 'View',
    onAction: onTap,
  );
}

String _rejectionReason(Map<String, dynamic> order) {
  final String text = (order['rejectionRemark'] ?? '').toString().trim();
  return text.isEmpty ? 'No reason given' : text;
}
