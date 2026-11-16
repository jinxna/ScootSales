import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:scoot_design/scoot_design.dart';

import '../copilot/mobile_copilot_page.dart';
import '../providers/auth_provider.dart';
import '../utils/stream_with_fallback.dart';
import '../widgets/long_name_text.dart';
import '../widgets/phone_card.dart';
import '../widgets/phone_status_strip.dart';
import 'overview_screen.dart' show AppBottomNav;

const int visitHistoryPageSize = 50;

class VisitEntry {
  const VisitEntry({
    required this.id,
    required this.name,
    required this.status,
    required this.time,
    required this.arrivalMode,
    required this.skipReason,
  });

  final String id;
  final String name;
  final String status;
  final DateTime? time;
  final String arrivalMode;
  final String skipReason;

  static DateTime? readTime(Map<String, dynamic> data) {
    final field = switch (data['status']) {
      'completed' => 'completedAt',
      'skipped' => 'skippedAt',
      _ => 'arrivedAt',
    };
    for (final key in [field, 'deviceOccurredAt', 'arrivedAt', 'updatedAt']) {
      final value = data[key];
      if (value is Timestamp) return value.toDate().toLocal();
    }
    return null;
  }

  factory VisitEntry.fromData(String id, Map<String, dynamic> data) {
    final Object? name = data['retailerName'];
    return VisitEntry(
      id: id,
      name: name is String && name.trim().isNotEmpty
          ? name.trim()
          : 'Unnamed retailer',
      status: '${data['status'] ?? ''}',
      time: readTime(data),
      arrivalMode: '${data['arrivalMode'] ?? ''}',
      skipReason: '${data['skipReason'] ?? ''}'.trim(),
    );
  }

  String get statusWord => switch (status) {
    'completed' => 'Completed',
    'skipped' => 'Skipped',
    _ => 'Arrived',
  };

  String get dayLabel =>
      time == null ? 'Date unavailable' : DateFormat('EEE d MMM').format(time!);
}

class VisitHistoryList extends StatelessWidget {
  const VisitHistoryList({super.key, required this.visits, this.onLoadMore});

  final List<VisitEntry> visits;
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final Map<String, List<VisitEntry>> byDay = <String, List<VisitEntry>>{};
    for (final VisitEntry visit in visits) {
      byDay.putIfAbsent(visit.dayLabel, () => []).add(visit);
    }
    return ListView(
      padding: const EdgeInsets.all(ScootSpace.phoneGutter),
      children: <Widget>[
        for (final MapEntry<String, List<VisitEntry>> day in byDay.entries) ...[
          PhoneSectionTitle(
            day.key,
            trailing: Text(
              '${day.value.length} ${day.value.length == 1 ? 'visit' : 'visits'}',
              style: ScootType.small.copyWith(color: c.muted),
            ),
          ),
          PhoneCard(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: <Widget>[
                for (int i = 0; i < day.value.length; i++) ...[
                  if (i > 0) const PhoneDivider(),
                  _VisitRow(visit: day.value[i]),
                ],
              ],
            ),
          ),
        ],
        if (onLoadMore != null) ...<Widget>[
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onLoadMore,
            child: const Text('Load older visits'),
          ),
        ],
      ],
    );
  }
}

class _VisitRow extends StatelessWidget {
  const _VisitRow({required this.visit});

  final VisitEntry visit;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final String time = visit.time == null
        ? 'Time unavailable'
        : DateFormat.jm().format(visit.time!);
    final String line = visit.status == 'skipped' && visit.skipReason.isNotEmpty
        ? 'Skipped · ${visit.skipReason} · $time'
        : '${visit.statusWord} · $time';
    final Widget badge = switch (visit.arrivalMode) {
      'location_verified' => const ScootBadge.approved(
        label: 'Verified location',
      ),
      'manual_unverified' => const ScootBadge.attention(
        label: 'Arrived without GPS · review pending',
      ),
      _ => const ScootBadge(label: 'Location not recorded'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LongNameText(
            visit.name,
            style: ScootType.bodyStrong.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(line, style: ScootType.small.copyWith(color: c.text2)),
          const SizedBox(height: 6),
          badge,
        ],
      ),
    );
  }
}

class MyVisitsScreen extends StatelessWidget {
  const MyVisitsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final uid = auth.isLoggedIn ? auth.user?.uid : null;
    return ScootPhoneScaffold(
      appBar: ScootPhoneAppBar(
        title: 'My visits',
        onBack: () => Navigator.of(context).maybePop(),
        actions: const <Widget>[CopilotEntryButton()],
      ),
      statusStrip: const PhoneStatusStrip(),
      body: uid == null
          ? const Center(child: Text('Sign in to view your visits.'))
          : _VisitHistory(key: ValueKey(uid), uid: uid),
      bottomNav: const AppBottomNav(currentIndex: 3),
    );
  }
}

class _VisitHistory extends StatefulWidget {
  const _VisitHistory({super.key, required this.uid});
  final String uid;

  @override
  State<_VisitHistory> createState() => _VisitHistoryState();
}

class _VisitHistoryState extends State<_VisitHistory> {
  late Stream<QuerySnapshot<Map<String, dynamic>>> _visits;
  int _limit = visitHistoryPageSize;

  @override
  void initState() {
    super.initState();
    _visits = _watchVisits();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _watchVisits() {
    final stops = FirebaseFirestore.instance
        .collection('route_stop_progress')
        .where('salesmanUid', isEqualTo: widget.uid);
    final int limit = _limit;
    return streamWithFallback<QuerySnapshot<Map<String, dynamic>>>(
      stops
          .orderBy('deviceOccurredAt', descending: true)
          .limit(limit)
          .snapshots,
      stops.limit(limit).snapshots,
      (Object error) =>
          error is FirebaseException && error.code == 'failed-precondition',
    );
  }

  void _retry() => setState(() => _visits = _watchVisits());

  void _loadMore() => setState(() {
    _limit += visitHistoryPageSize;
    _visits = _watchVisits();
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _visits,
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? const [];
        final visits = docs
            .where((doc) {
              final data = doc.data();
              return data['salesmanUid'] == widget.uid &&
                  ['arrived', 'completed', 'skipped'].contains(data['status']);
            })
            .map((doc) => VisitEntry.fromData(doc.id, doc.data()))
            .toList();
        visits.sort((a, b) {
          final aTime = a.time;
          final bTime = b.time;
          final order = aTime == null
              ? (bTime == null ? 0 : 1)
              : (bTime == null ? -1 : bTime.compareTo(aTime));
          return order == 0 ? a.id.compareTo(b.id) : order;
        });
        return PhoneStateBody(
          error: snapshot.hasError,
          errorTitle: 'Your visits did not load',
          loading: !snapshot.hasData && !snapshot.hasError,
          onRetry: _retry,
          empty: visits.isEmpty,
          emptyIcon: ScootIcons.visitLogs,
          emptyTitle: 'No visits yet',
          emptyMessage:
              'Your arrivals, completed visits and skipped stops appear here.',
          child: VisitHistoryList(
            visits: visits,
            onLoadMore: docs.length >= _limit ? _loadMore : null,
          ),
        );
      },
    );
  }
}
