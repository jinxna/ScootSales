import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/build_flags.dart';
import '../../models/action_centre_item.dart';
import '../../pages/admin/widgets/order_details_dialog.dart';
import '../../repositories/cms_repository.dart';
import '../../services/csv_downloader.dart';
import '../../utils/order_data_utils.dart';
import '../../utils/order_id_resolver.dart';
import '../../models/user_profile.dart';
import '../../services/action_centre_service.dart';
import '../../services/audit_log_service.dart';
import '../../services/visit_priority_service.dart';
import '../dashboard_voice_engine.dart';
import '../dashboard_voice_policy.dart';
import '../dashboard_voice_speech.dart';
import '../dashboard_voice_types.dart';
import '../../theme/dso_colors.dart';
import 'copilot_client.dart';
import 'copilot_controller.dart';
import 'copilot_entity_resolver.dart';
import 'copilot_grammar.dart';
import 'copilot_order_widgets.dart';
import 'copilot_rank_why.dart';
import 'copilot_status.dart';
import 'order_search_session.dart';
import 'copilot_widgets.dart';

const double kCopilotPanelWidth = 380;
const int _briefingLimit = 5;

const int kCopilotOrderWindowCap = 2000;

const List<String> kCopilotDashboardActions = <String>[
  'daily_briefing',
  'explain_item',
  'set_item_status',
  'search_orders',
  'export_results',
];

List<String> get copilotDashboardActions => isBasicEdition
    ? const <String>['search_orders', 'export_results']
    : kCopilotDashboardActions;

class CopilotPanel extends StatefulWidget {
  const CopilotPanel({
    super.key,
    required this.currentUser,
    required this.pages,
    required this.onPageRequested,
    required this.onClose,
    required this.status,
    this.fill = false,
    this.service,
    this.server,
  });

  final UserProfile currentUser;
  final List<DashboardVoicePage> pages;
  final DashboardVoicePageHandler onPageRequested;
  final VoidCallback onClose;

  final bool fill;
  final ActionCentreService? service;

  final CopilotServerStatus status;

  final CopilotServerClient? server;

  @override
  State<CopilotPanel> createState() => _CopilotPanelState();
}

class _CopilotPanelState extends State<CopilotPanel> {
  late final ActionCentreService _service =
      widget.service ?? ActionCentreService();
  late final CopilotController _controller;
  late final DashboardVoiceEngine _engine;
  late final DashboardVoiceSpeechSession _speech;
  CopilotServerClient? get _server => widget.server;
  bool _asking = false;
  String _askingText = '';
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode(debugLabel: 'copilot input');
  bool _listening = false;
  static const String _speechLocale = 'en_US';
  int _captures = 0;
  int _epoch = 0;
  FocusNode? _returnFocus;
  final FocusScopeNode _composerScope = FocusScopeNode(
    debugLabel: 'copilot composer',
  );

  @override
  void initState() {
    super.initState();
    _returnFocus = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final FocusNode node in _composerScope.traversalDescendants) {
        if (node.canRequestFocus) {
          node.requestFocus();
          return;
        }
      }
    });
    final UserProfile user = widget.currentUser;
    _engine = DashboardVoiceEngine();
    _speech = DashboardVoiceSpeechSession();
    _controller = CopilotController(
      allowed: user.docId.trim().isNotEmpty && user.isActive,
      memory: widget.status.memory,
      orders: _buildOrderSession(user),
      openOrder: _openOrder,
      openPage: _openKnownPage,
      explainRank: isBasicEdition ? null : _rankExplainer(user),
      advanced: !isBasicEdition,
      routesViewOnly: user.isBranchManager,
      ordersViewOnly: user.isBranchManager,
      loadItems: () async {
        final ActionCentreLoadResult all = await _service
            .loadAllItemsWithHealth(currentUser: user);
        return (
          items: all.items
              .where((ActionCentreItem i) => i.isVisible)
              .take(_briefingLimit)
              .toList(growable: false),
          failedSources: all.failedSources,
        );
      },
      readStatus: (String id) =>
          _service.readWorkflowStatus(currentUser: user, actionId: id),
      writeStatus:
          (ActionCentreItem item, String expected, String status) async {
            final bool wrote = await _service.setStatusIfUnchanged(
              currentUser: user,
              actionId: item.id,
              expectedStatus: expected,
              status: status,
            );
            if (!wrote) return false;
            await AuditLogService.instance.record(
              action: 'action_centre_status',
              entityType: 'action_centre_item',
              entityId: item.id,
              summary: 'Set "${item.title}" to ${copilotStatusLabel(status)}',
              actor: user,
              metadata: <String, dynamic>{
                'source': 'assistant',
                'status': status,
              },
            );
            return true;
          },
    )..addListener(_onChange);
    widget.status.addListener(_onStatus);
    FocusManager.instance.addListener(_onFocusChange);
    unawaited(widget.status.wake());
  }

  OrderSearchSession? _buildOrderSession(UserProfile user) {
    if (!(user.isAdmin ||
        user.isDeveloper ||
        user.isSupervisor ||
        user.isBranchManager)) {
      return null;
    }
    CmsRepository? cached;
    CmsRepository repository() => cached ??= CmsRepository();
    final Set<String> assigned = <String>{
      for (final String code in user.assignedSalesmanCodes)
        if (code.trim().isNotEmpty) code.trim().toLowerCase(),
    };
    final String branch = user.branchId.trim().toLowerCase();
    bool inScope(Map<String, dynamic> row) {
      if (user.isAdmin || user.isDeveloper) return true;
      if (user.isBranchManager) {
        return branch.isNotEmpty &&
            '${row['branchId'] ?? ''}'.trim().toLowerCase() == branch;
      }
      final String code = '${row['employeeCode'] ?? row['userId'] ?? ''}'
          .trim()
          .toLowerCase();
      return code.isNotEmpty && assigned.contains(code);
    }

    return OrderSearchSession(
      scopeNote: user.isSupervisor && assigned.isEmpty
          ? 'You have no salespeople assigned, so there are no orders to search.'
          : user.isBranchManager && branch.isEmpty
          ? 'Your account has no branch, so there are no orders to search.'
          : null,
      readWindow: (DateTime start, DateTime end) async {
        final OrderWindowRead read = await repository()
            .getOrdersSubmittedBetween(
              start: start,
              end: end,
              maxDocuments: kCopilotOrderWindowCap,
            );
        return OrderWindow(rows: read.rows, truncated: read.truncated);
      },
      countWaiting: () => repository().countPendingApprovalOrders(),
      loadSalespeople: () async {
        final List<Map<String, dynamic>> users = await repository()
            .getCollectionOnce('users');
        return <EntityRef>[
          for (final Map<String, dynamic> row in users)
            if (!isDemoRow(row) &&
                '${row['role'] ?? ''}'.toLowerCase() == 'salesman' &&
                inScope(row))
              _salespersonRef(row),
        ];
      },
      download: (String filename, String csv) =>
          downloadCsv(filename: filename, csv: csv),
      recordExport: (OrderResultSet set, String filename) =>
          AuditLogService.instance.record(
            action: 'copilot_order_export',
            entityType: 'orders',
            entityId: 'search',
            summary:
                'Exported ${set.rows.length} orders (${set.query.period.label})',
            actor: user,
            metadata: <String, dynamic>{
              'source': 'assistant',
              'rowCount': set.rows.length,
              'truncated': set.truncated,
              'period': set.query.period.kind.name,
              'periodLabel': set.query.period.label,
              'start': set.start.toIso8601String(),
              'end': set.end.toIso8601String(),
              'salespersonId': set.query.salesperson?.id,
              'retailerId': set.query.retailer?.id,
              'status': set.query.status,
              'filename': filename,
            },
          ),
    );
  }

  Future<CopilotReply> Function(RankWhyIntent)? _rankExplainer(
    UserProfile user,
  ) {
    if (!(user.isAdmin || user.isSupervisor || user.isBranchManager)) {
      return null;
    }
    VisitPriorityService? cached;
    return (RankWhyIntent intent) async {
      final VisitPriorityService service = cached ??= VisitPriorityService();
      return explainRetailerRank(intent.name, await service.loadRankings(user));
    };
  }

  EntityRef _salespersonRef(Map<String, dynamic> row) {
    String text(Object? v) => '${v ?? ''}'.trim();
    final String uid = text(row['uid'] ?? row['userUid']);
    final String code = text(row['employeeCode'] ?? row['userId']);
    final String staff = text(row['staffId']);
    final String name = text(row['name']).isEmpty
        ? text(row['email'])
        : text(row['name']);
    return EntityRef(
      kind: EntityKind.salesperson,
      id: uid.isEmpty ? text(row['docId']) : uid,
      name: name,
      code: code,
      orderKeys: <String>{
        for (final String key in <String>[uid, code, staff])
          if (key.isNotEmpty) key.toLowerCase(),
      },
    );
  }

  void _openOrder(Map<String, dynamic> order) {
    if (!mounted) return;
    unawaited(
      OrderDetailsDialog.show(
        context,
        orderDocumentId: OrderIdResolver.resolve(order),
        initialOrder: order,
        currentUser: widget.currentUser,
        showActions: false,
      ).whenComplete(_refocus),
    );
  }

  Future<bool> _openKnownPage(String key) async {
    if (!mounted) return false;
    for (final String candidate in <String>[key, ...?_pageFallbacks[key]]) {
      if (widget.pages.any((DashboardVoicePage p) => p.key == candidate)) {
        await _showPage(candidate);
        return true;
      }
    }
    return false;
  }

  static const Map<String, List<String>> _pageFallbacks =
      <String, List<String>>{
        'all_orders': <String>['team_orders'],
        'salesman_activity': <String>['team_activity'],
        'visit_logs': <String>['team_visits'],
        'prediction': <String>['team_forecast'],
        'reports': <String>['team_reports'],
        'retailer_coordinates': <String>['retailer'],
        'salesman': <String>['salesman_activity', 'user_directory', 'my_team'],
        'conversation_outcome': <String>['visit_logs', 'team_visits'],
      };

  Future<void> _openItem(ActionCentreItem item) async {
    final String type = item.relatedEntityType.trim().toLowerCase();
    final String id = item.relatedEntityId.trim();
    if (type == 'order' && id.isNotEmpty) {
      unawaited(
        OrderDetailsDialog.show(
          context,
          orderDocumentId: id,
          currentUser: widget.currentUser,
          showActions: false,
        ).whenComplete(() => _refocus()),
      );
      return;
    }
    final String key = item.relatedPageKey.trim();
    for (final String candidate in <String>[
      if (key.isNotEmpty) key,
      ...?_pageFallbacks[key],
    ]) {
      final DashboardVoicePage? page = widget.pages
          .where((DashboardVoicePage p) => p.key == candidate)
          .firstOrNull;
      if (page == null) continue;
      await _showPage(page.key);
      if (mounted) _reply('Open ${item.title}', 'Opened ${page.label}.');
      _refocus();
      return;
    }
    _reply('Open ${item.title}', 'That page is not available to your role.');
    _refocus();
  }

  Future<void> _showPage(String key) async {
    await widget.onPageRequested(key);
    _pageOpened = true;
  }

  void _refocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _listening || _controller.busy || _asking) return;
      final ModalRoute<dynamic>? route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      if (_pageOpened) {
        _pageOpened = false;
        _reclaimUntil = DateTime.now().add(const Duration(seconds: 1));
        if (_inputFocus.hasFocus) {
          _inputFocus.unfocus();
          _refocus();
          return;
        }
      }
      if (!_inputFocus.hasFocus) _inputFocus.requestFocus();
    });
  }

  bool _pageOpened = false;
  DateTime _reclaimUntil = DateTime.fromMillisecondsSinceEpoch(0);

  void _onFocusChange() {
    if (DateTime.now().isBefore(_reclaimUntil) && !_inputFocus.hasFocus) {
      _refocus();
    }
  }

  void _onStatus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.status.removeListener(_onStatus);
    FocusManager.instance.removeListener(_onFocusChange);
    _controller
      ..removeListener(_onChange)
      ..dispose();
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    _composerScope.dispose();
    unawaited(_speech.dispose());
    final FocusNode? back = _returnFocus;
    if (back != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (back.context != null && back.canRequestFocus) back.requestFocus();
      });
    }
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _submit(String raw) async {
    final String text = raw.trim();
    if (text.isEmpty || _controller.busy || _asking) return;
    _input.clear();
    try {
      final CopilotIntent? intent = interpretCopilot(text);
      if (intent != null) {
        await _controller.run(intent, text);
        return;
      }
      _controller.invalidatePending();
      if (await _openPage(text)) return;
      await _askModel(text);
    } finally {
      _refocus();
    }
  }

  void _reply(String text, String answer) => _controller.exchange(text, answer);

  void _unreachable(String text) => _controller.exchange(
    text,
    'Check your connection. Fixed commands still work.',
    kind: CopilotEntryKind.error,
    retryText: text,
  );

  void _retry(String text) {
    _controller.dropLastExchange();
    unawaited(_submit(text));
  }

  Future<void> _newChat() async {
    _epoch++;
    if (_listening) await _speech.stop();
    if (!mounted) return;
    _input.clear();
    setState(() {
      _asking = false;
      _listening = false;
    });
    _controller.newChat();
    _refocus();
  }

  Future<void> _askModel(String text) async {
    const String lost = 'I did not understand that. Try one of these.';
    final CopilotServerState serverState = widget.status.value;
    if (serverState == CopilotServerState.offline) return _unreachable(text);
    if (serverState != CopilotServerState.ready) {
      _reply(
        text,
        serverState == CopilotServerState.waking
            ? 'I did not understand that. The assistant model is still waking up. Try one of these.'
            : lost,
      );
      return;
    }
    final int epoch = _epoch;
    setState(() {
      _asking = true;
      _askingText = text;
    });
    CopilotProposal? proposal;
    String? failure;
    bool unreachable = false;
    try {
      proposal = await _server!.interpret(
        text: text,
        pages: widget.pages,
        actions: copilotDashboardActions,
      );
    } on CopilotServerBusy {
      failure = 'The assistant model is busy. Try again in a moment.';
    } on CopilotServerUnreachable {
      unreachable = true;
      widget.status.serverUnreachable();
    } on CopilotAssistantUnavailable catch (error) {
      failure = switch (error.reason) {
        'person_limit' =>
          'You have used your share of assistant requests for today. It resets at midnight, Malaysia time.',
        'company_limit' =>
          'Your company has used all its assistant requests for today. They reset at midnight, Malaysia time.',
        _ => 'Assistant is not available now. Try again later.',
      };
    }
    if (!mounted) return;
    if (epoch != _epoch) return;
    setState(() => _asking = false);
    _refocus();
    if (unreachable) return _unreachable(text);
    if (failure != null) return _reply(text, failure);
    if (proposal == null) return _reply(text, lost);
    if (proposal.name == 'navigate_to_page') {
      final Object? key = proposal.args['page'];
      final DashboardVoicePolicyDecision decision =
          const DashboardVoicePolicyGateway().evaluate(
            interpretation: DashboardVoiceInterpretation(
              action: DashboardVoiceActionId.openPage,
              pageKey: key is String ? key : '',
              normalizedTranscript: text,
            ),
            pages: widget.pages,
            role: widget.currentUser.role,
            isAuthenticated: widget.currentUser.docId.trim().isNotEmpty,
            isActive: widget.currentUser.isActive,
          );
      if (!decision.isAllowed) return _reply(text, lost);
      await _showPage(decision.page!.key);
      return _reply(text, 'Opened ${decision.page!.label}.');
    }
    final CopilotIntent? intent = intentFromCall(proposal.name, proposal.args);
    if (intent == null) {
      return _reply(text, 'That request is not available yet.');
    }
    await _controller.run(intent, text);
  }

  Future<bool> _openPage(String text) async {
    final DashboardVoiceEngineOutcome outcome = await _engine
        .submitFinalTranscript(
          transcript: text,
          captureId: 'copilot-${++_captures}',
          pages: widget.pages,
          role: widget.currentUser.role,
          isAuthenticated: widget.currentUser.docId.trim().isNotEmpty,
          isActive: widget.currentUser.isActive,
          onPageRequested: (String key) async {
            if (!mounted) throw StateError('The Scout panel was closed.');
            await _showPage(key);
          },
        );
    if (!mounted) return true;
    final String? reply = switch (outcome.code) {
      DashboardVoiceResultCode.opened => 'Opened ${outcome.page!.label}.',
      DashboardVoiceResultCode.rejected =>
        'This account cannot open that page.',
      DashboardVoiceResultCode.executionFailed =>
        'The page did not open. Try again.',
      DashboardVoiceResultCode.duplicate => '',
      DashboardVoiceResultCode.abstained => null,
    };
    if (reply == null) return false;
    if (reply.isNotEmpty) _reply(text, reply);
    return true;
  }

  Future<void> _cancelSpeech() async {
    await _speech.stop();
    if (!mounted) return;
    _input.clear();
    setState(() => _listening = false);
    _refocus();
  }

  Future<void> _toggleSpeech() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    setState(() => _listening = true);
    final bool started = await _speech.start(
      localeId: _speechLocale,
      onPartial: (String t) {
        if (!mounted) return;
        _input.text = t;
        _input.selection = TextSelection.collapsed(offset: t.length);
      },
      onFinal: (String t) {
        if (!mounted) return;
        setState(() => _listening = false);
        unawaited(_submit(t));
      },
      onError: (String _) {
        if (mounted) setState(() => _listening = false);
      },
      onStopped: () {
        if (mounted) setState(() => _listening = false);
      },
    );
    if (!started && mounted) setState(() => _listening = false);
  }

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final bool working = _controller.busy || _asking;
    final bool empty = _controller.entries.isEmpty && !working;
    final int shown = _controller.entries.length;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Semantics(
        container: true,
        label: 'Scout panel',
        child: Container(
          width: widget.fill ? null : kCopilotPanelWidth,
          decoration: BoxDecoration(
            color: dso.card,
            border: Border(left: BorderSide(color: dso.hairline)),
          ),
          child: Column(
            children: <Widget>[
              CopilotHeader(
                onClose: widget.onClose,
                onNewChat: empty ? null : _newChat,
              ),
              if (!empty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: CopilotStatusLine(state: widget.status.value),
                ),
              if (_controller.shownItems.isNotEmpty ||
                  _controller.focus != null)
                CopilotContextStrip(
                  key: const ValueKey<String>('copilot-context'),
                  itemsShown: _controller.shownItems.length,
                  focus: _controller.focus,
                  onClearFocus: _controller.clearFocus,
                ),
              Expanded(
                key: const ValueKey<String>('copilot-transcript'),
                child: empty
                    ? CopilotHero(
                        scope: _scope,
                        firstName: _firstName,
                        state: widget.status.value,
                        now: DateTime.now(),
                      )
                    : Semantics(
                        container: true,
                        liveRegion: true,
                        child: SelectionArea(
                          child: ListView.separated(
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                            itemCount:
                                shown + (_asking ? 2 : (working ? 1 : 0)),
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (BuildContext context, int i) =>
                                i < shown
                                ? _entry(_controller.entries[i], i)
                                : _asking && i == shown
                                ? CopilotUserBubble(text: _askingText)
                                : const CopilotTypingDots(),
                          ),
                        ),
                      ),
              ),
              ..._suggestions(empty: empty, working: working),
              FocusScope(
                key: const ValueKey<String>('copilot-composer'),
                node: _composerScope,
                child: CopilotComposer(
                  controller: _input,
                  focusNode: _inputFocus,
                  enabled: !working,
                  listening: _listening,
                  onCancelListening: _cancelSpeech,
                  onMic: _toggleSpeech,
                  onSend: () => _submit(_input.text),
                  onSubmitted: _submit,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _firstName {
    final String name = widget.currentUser.name.trim();
    return name.isEmpty ? 'there' : name.split(RegExp(r'\s+')).first;
  }

  String get _scope {
    final UserProfile user = widget.currentUser;
    final String branch = user.isAdmin || user.isDeveloper
        ? 'All branches'
        : user.branchId.trim();
    return branch.isEmpty ? user.roleLabel : '${user.roleLabel} · $branch';
  }

  List<Widget> _suggestions({required bool empty, required bool working}) {
    final List<String> list;
    if (empty) {
      list = copilotFirstSuggestions(
        widget.currentUser,
        advanced: !isBasicEdition,
      );
    } else if (working ||
        _controller.pending != null ||
        _controller.liveExportCard != null ||
        _controller.liveChoiceCard != null ||
        _controller.entries.last.fromUser) {
      return const <Widget>[];
    } else {
      list = copilotFollowUps(
        _controller.memory.lastIntent,
        advanced: !isBasicEdition,
      );
    }
    return <Widget>[
      CopilotSuggestions(
        label: empty ? 'Try asking' : 'Next, you could ask',
        suggestions: list,
        onPick: _submit,
      ),
    ];
  }

  Widget _entry(CopilotEntry entry, int index) {
    if (entry.fromUser) return CopilotUserBubble(text: entry.text);
    final PendingStatusChange? pending = entry.pending;
    final bool live =
        pending != null && identical(pending, _controller.pending);
    final bool last = index == _controller.entries.length - 1;
    final DsoColors dso = context.dso;
    return CopilotAssistantRow(
      kind: entry.kind,
      children: <Widget>[
        if (!live)
          switch (entry.kind) {
            CopilotEntryKind.answer => CopilotText(entry.text),
            CopilotEntryKind.refusal => CopilotText(
              entry.text,
              title: "I can't do that",
              titleColor: dso.warningText,
            ),
            CopilotEntryKind.error => CopilotText(
              entry.text,
              title: 'Could not reach the server',
              titleColor: dso.dangerText,
            ),
          },
        if (entry.kind == CopilotEntryKind.error &&
            entry.retryText != null &&
            last &&
            !(_controller.busy || _asking))
          CopilotRetryButton(onPressed: () => _retry(entry.retryText!)),
        if (entry.items != null)
          CopilotItemList(
            items: entry.items!.map(_current).toList(),
            onOpenItem: _openItem,
          ),
        ..._orderCard(entry.card),
        if (live)
          CopilotConfirmCard(
            pending: pending,
            busy: _controller.busy || _asking,
            onConfirm: _controller.confirmPending,
            onCancel: _controller.cancelPending,
          ),
      ],
    );
  }

  List<Widget> _orderCard(Object? card) {
    final bool working = _controller.busy || _asking;
    if (card is OrderResultsCard) {
      return <Widget>[
        CopilotOrderResultsView(
          card: card,
          onOpen: (int n) =>
              _controller.run(OpenResultIntent(n), 'Open order $n'),
          onOpenAllOrders: () async {
            await _showPage('all_orders');
            _refocus();
          },
        ),
      ];
    }
    if (card is RankWhyCard) return <Widget>[CopilotRankWhyView(card: card)];
    if (card is ChoiceCard) {
      return <Widget>[
        CopilotChoiceView(
          card: card,
          enabled: !working && identical(card, _controller.liveChoiceCard),
          onPick: (int n) => _controller.run(PickIntent(n), 'Choice $n'),
        ),
      ];
    }
    if (card is ExportCard) {
      return <Widget>[
        CopilotExportView(
          card: card,
          live: identical(card, _controller.liveExportCard),
          busy: working,
          expiresAt: _controller.orders?.pendingExport?.expiresAt,
          onConfirm: _controller.confirmPending,
          onCancel: _controller.cancelPending,
        ),
      ];
    }
    return const <Widget>[];
  }

  ActionCentreItem _current(ActionCentreItem item) => _controller.shownItems
      .firstWhere((ActionCentreItem i) => i.id == item.id, orElse: () => item);
}
