import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../models/user_profile.dart';
import '../../../services/csv_downloader.dart';
import '../../../utils/csv_export.dart';
import '../../../widgets/page_states.dart';
import '../../../widgets/tip_text.dart';

class AuditEntry {
  const AuditEntry({
    required this.action,
    required this.summary,
    required this.entityType,
    required this.entityId,
    required this.actor,
    required this.createdAt,
    this.email = '',
    this.role = '',
    this.name = '',
    this.userId = '',
  });

  factory AuditEntry.fromMap(Map<String, dynamic> data) {
    final Object? raw = data['createdAt'];
    return AuditEntry(
      action: '${data['action'] ?? ''}'.toLowerCase(),
      summary: '${data['summary'] ?? 'Audit event'}',
      entityType: '${data['entityType'] ?? 'record'}',
      entityId: '${data['entityId'] ?? ''}',
      actor: _actorLabel(data),
      email: _field(data, 'actorEmail'),
      role: _role(data),
      name: _field(data, 'actorName'),
      userId: _field(data, 'actorUid'),
      createdAt: raw is Timestamp
          ? raw.toDate()
          : raw is DateTime
          ? raw
          : null,
    );
  }

  final String action;
  final String summary;
  final String entityType;
  final String entityId;
  final String actor;
  final String email;
  final String role;
  final String name;
  final String userId;
  final DateTime? createdAt;

  String get searchText =>
      '$summary $entityType $entityId $actor'.toLowerCase();
}

String _field(Map<String, dynamic> data, String key) =>
    '${data[key] ?? ''}'.trim();

String _role(Map<String, dynamic> data) {
  final String role = _field(data, 'actorRole');
  return role == 'unauthenticated' ? '' : role;
}

String _actorLabel(Map<String, dynamic> data) {
  final String email = _field(data, 'actorEmail');
  final String role = _role(data);
  final String name = _field(data, 'actorName');
  final String uid = _field(data, 'actorUid');
  final String verified = <String>[
    email,
    role,
  ].where((String part) => part.isNotEmpty).join(', ');
  if (verified.isNotEmpty) {
    return name.isEmpty || name == email
        ? verified
        : '$verified (name given: $name)';
  }
  if (uid.isNotEmpty) {
    return name.isEmpty
        ? 'User ID $uid (not verified)'
        : '$name (not verified, user ID $uid)';
  }
  return name.isEmpty ? 'System' : name;
}

const List<String> auditActionFilters = <String>[
  'all',
  'created',
  'updated',
  'deleted',
  'approved',
  'rejected',
  'published',
  'imported',
];

const Duration auditRange = Duration(days: 30);

class AuditLogPage extends StatefulWidget {
  const AuditLogPage({super.key, required this.currentUser});

  final UserProfile currentUser;

  @override
  State<AuditLogPage> createState() => _AuditLogPageState();
}

class _AuditLogPageState extends State<AuditLogPage> {
  int _pages = 1;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _stream = _open();

  Stream<QuerySnapshot<Map<String, dynamic>>> _open() => FirebaseFirestore
      .instance
      .collection('system_audit_logs')
      .orderBy('createdAt', descending: true)
      .limit(ScootPaging.pageSize * _pages)
      .snapshots();

  void _reload() => setState(() => _stream = _open());

  void _loadMore() => setState(() {
    _pages++;
    _stream = _open();
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _stream,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
          ) {
            final QuerySnapshot<Map<String, dynamic>>? data = snapshot.data;
            final ScootLoadPhase phase = snapshot.hasError
                ? ScootLoadPhase.error
                : data == null
                ? ScootLoadPhase.loading
                : ScootLoadPhase.ready;
            return AuditLogView(
              phase: phase,
              error: snapshot.error,
              fromCache: data?.metadata.isFromCache ?? false,
              entries: <AuditEntry>[
                for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
                    in data?.docs ??
                        const <QueryDocumentSnapshot<Map<String, dynamic>>>[])
                  AuditEntry.fromMap(doc.data()),
              ],
              hasMore:
                  data != null &&
                  data.docs.length >= ScootPaging.pageSize * _pages,
              onLoadMore: _loadMore,
              onRetry: _reload,
              now: DateTime.now(),
            );
          },
    );
  }
}

class AuditLogView extends StatefulWidget {
  const AuditLogView({
    super.key,
    required this.phase,
    required this.entries,
    required this.onRetry,
    required this.now,
    this.error,
    this.fromCache = false,
    this.hasMore = false,
    this.onLoadMore,
  });

  final ScootLoadPhase phase;
  final List<AuditEntry> entries;
  final VoidCallback onRetry;
  final DateTime now;
  final Object? error;
  final bool fromCache;
  final bool hasMore;
  final VoidCallback? onLoadMore;

  @override
  State<AuditLogView> createState() => _AuditLogViewState();
}

class _AuditLogViewState extends State<AuditLogView> {
  String _action = 'all';
  bool _lastMonthOnly = false;
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _filtered =>
      _action != 'all' || _lastMonthOnly || _search.text.trim().isNotEmpty;

  List<AuditEntry> get _rows {
    final String query = _search.text.trim().toLowerCase();
    final DateTime since = widget.now.subtract(auditRange);
    return widget.entries
        .where((AuditEntry e) {
          if (_action != 'all' && e.action != _action) return false;
          if (_lastMonthOnly &&
              (e.createdAt == null || e.createdAt!.isBefore(since))) {
            return false;
          }
          return query.isEmpty || e.searchText.contains(query);
        })
        .toList(growable: false);
  }

  void _clear() => setState(() {
    _action = 'all';
    _lastMonthOnly = false;
    _search.clear();
  });

  void _export(List<AuditEntry> rows) {
    final bool ok = downloadCsv(
      filename: 'audit_log.csv',
      csv: buildCsv(
        <String>[
          'Time',
          'Who',
          'Email',
          'Role',
          'Name given',
          'User ID',
          'Action',
          'Record',
          'What changed',
        ],
        <List<Object?>>[
          for (final AuditEntry e in rows)
            <Object?>[
              _time(e.createdAt),
              e.actor,
              e.email,
              e.role,
              e.name,
              e.userId,
              _label(e.action),
              '${e.entityType} ${e.entityId}'.trim(),
              e.summary,
            ],
        ],
      ),
    );
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Export is only available in the web build.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final List<AuditEntry> rows = _rows;
    final bool ready = widget.phase == ScootLoadPhase.ready;
    final bool denied = isPermissionDenied(widget.error);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.fromCache && ready) ...<Widget>[
          const OfflineNotice(what: 'saved entries'),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 320,
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(ScootIcons.search),
                  hintText: 'Search action, record, ID or person',
                ),
              ),
            ),
            for (final String action in auditActionFilters)
              ChoiceChip(
                label: Text(_label(action)),
                selected: _action == action,
                onSelected: (_) => setState(() => _action = action),
              ),
            FilterChip(
              label: const Text('Last 30 days'),
              selected: _lastMonthOnly,
              onSelected: (bool v) => setState(() => _lastMonthOnly = v),
            ),
            if (ready)
              OutlinedButton.icon(
                onPressed: rows.isEmpty ? null : () => _export(rows),
                icon: const Icon(ScootIcons.download, size: 18),
                label: const Text('Export CSV'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ScootCard(
            fill: true,
            padding: EdgeInsets.zero,
            child: denied
                ? const ScootEmptyState(
                    icon: ScootIcons.lock,
                    title: 'You cannot open this page',
                    message:
                        'Your role does not include it. Ask an administrator.',
                  )
                : ScootDataTable<AuditEntry>(
                    phase: widget.phase,
                    rows: rows,
                    onRetry: widget.onRetry,
                    hasMore: widget.hasMore && !_filtered,
                    onLoadMore: widget.onLoadMore,
                    pagesLoaded: 1 << 20,
                    emptyTitle: _filtered
                        ? 'No entries match'
                        : 'No changes recorded yet',
                    emptyMessage: _filtered
                        ? 'Clear the search or pick another action.'
                        : 'Changes to routes, imports, the catalogue, users, forecasts and settings show here.',
                    emptyAction: _filtered
                        ? OutlinedButton(
                            onPressed: _clear,
                            child: const Text('Clear filters'),
                          )
                        : null,
                    countLabel: '${rows.length} entries · cannot be edited',
                    columns: <ScootTableColumn<AuditEntry>>[
                      ScootTableColumn<AuditEntry>(
                        label: 'Time',
                        width: 170,
                        cell: (_, AuditEntry e) => Text(_time(e.createdAt)),
                      ),
                      ScootTableColumn<AuditEntry>(
                        label: 'Who',
                        flex: 2,
                        cell: (_, AuditEntry e) => TipText(e.actor),
                      ),
                      ScootTableColumn<AuditEntry>(
                        label: 'Action',
                        width: 150,
                        cell: (_, AuditEntry e) =>
                            ScootBadge(label: _label(e.action)),
                      ),
                      ScootTableColumn<AuditEntry>(
                        label: 'Record',
                        flex: 2,
                        cell: (_, AuditEntry e) =>
                            TipText('${e.entityType} ${e.entityId}'.trim()),
                      ),
                      ScootTableColumn<AuditEntry>(
                        label: 'What changed',
                        flex: 3,
                        cell: (_, AuditEntry e) => TipText(
                          e.summary,
                          style: ScootType.body.copyWith(color: c.ink),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

String _label(String action) {
  if (action == 'all') return 'All';
  if (action == 'reset_demo') return 'Maintenance reset';
  if (action.isEmpty) return 'Event';
  final String text = action.replaceAll('_', ' ');
  return text[0].toUpperCase() + text.substring(1);
}

String _time(DateTime? value) {
  if (value == null) return 'Pending';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}
