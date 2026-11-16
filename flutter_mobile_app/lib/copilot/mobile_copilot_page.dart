import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../edition.dart';
import '../providers/auth_provider.dart';
import '../providers/connectivity_provider.dart';
import '../screens/assigned_route_screen.dart';
import '../screens/order_history_screen.dart';
import '../screens/overview_screen.dart' show overviewGreetingFor;
import '../screens/planner_screen.dart';
import '../screens/profile_screen.dart';
import 'mobile_copilot_answers.dart';
import 'mobile_copilot_bar.dart';
import 'mobile_copilot_commands.dart';
import 'mobile_copilot_controller.dart';
import 'mobile_copilot_server.dart';

const Color _surface = Color(0xFFF5F8F5);
const Color _line = Color(0xFFD3DBD6);
const Color _fieldLine = Color(0xFFC5CFC9);
const Color _errorRed = Color(0xFF9B2118);
const int _maxLength = 200;

bool _sheetOpen = false;

Future<void> openMobileCopilot(
  BuildContext context, {
  CopilotScreenContext? screen,
}) {
  final MobileCopilotController controller = context
      .read<MobileCopilotController>();
  if (_sheetOpen || context.read<AuthProvider>().user == null) {
    return Future<void>.value();
  }
  _sheetOpen = true;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: _surface,
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => MobileCopilotPage(controller: controller, screen: screen),
  ).whenComplete(() => _sheetOpen = false);
}

class CopilotEntryButton extends StatelessWidget {
  const CopilotEntryButton({super.key, this.screen});

  final CopilotScreenContext? screen;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Open Scout',
      excludeSemantics: true,
      child: Material(
        color: const Color(0xFFEAF3ED),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => openMobileCopilot(context, screen: screen),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.mic_none, size: 16, color: kCopilotDeepGreen),
                  SizedBox(width: 6),
                  Text(
                    'Scout',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: kCopilotDeepGreen,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget _screenFor(CopilotDestination destination) {
  switch (destination) {
    case CopilotDestination.route:
      return const AssignedRouteScreen();
    case CopilotDestination.orders:
      return const OrderHistoryScreen();
    case CopilotDestination.planner:
      return const PlannerScreen();
    case CopilotDestination.profile:
      return const ProfileScreen();
  }
}

class MobileCopilotPage extends StatefulWidget {
  const MobileCopilotPage({super.key, required this.controller, this.screen});

  final MobileCopilotController controller;
  final CopilotScreenContext? screen;

  @override
  State<MobileCopilotPage> createState() => _MobileCopilotPageState();
}

class _MobileCopilotPageState extends State<MobileCopilotPage> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();
  bool _wasListening = false;
  bool _expanded = true;
  int _shownItems = 0;
  int _pendingConfirms = 0;

  int _ownRoutes = 0;
  bool _removing = false;

  MobileCopilotController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.openHandler = _open;
    _c.closeHandler = _close;
    _c.attachScreen(widget.screen);
    _c.addListener(_onController);
    _c.loadFirstRetailer();
    MobileCopilotServer.warmUp();
  }

  @override
  void dispose() {
    _c.removeListener(_onController);
    if (_c.openHandler == _open) _c.openHandler = null;
    if (_c.closeHandler == _close) _c.closeHandler = null;
    _c.detachScreen();
    _c.cancelListening();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _open(CopilotDestination destination) {
    if (!mounted) return;
    final NavigatorState navigator = Navigator.of(context);
    _close();
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => _screenFor(destination)),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route == null || route.isCurrent || _ownRoutes > 0 || _removing) {
      return;
    }
    _removing = true;
    final NavigatorState navigator = Navigator.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive && !route.isCurrent) navigator.removeRoute(route);
    });
  }

  Future<T?> _overSheet<T>(Future<T?> Function() show) async {
    _ownRoutes++;
    try {
      return await show();
    } finally {
      _ownRoutes--;
    }
  }

  void _close() {
    if (!mounted) return;
    _focus.unfocus();
    if (ModalRoute.of(context)?.isCurrent ?? false) Navigator.of(context).pop();
  }

  Future<void> _copyEvaluation() async {
    final String json = await _c.evaluation?.exportJson() ?? '';
    if (json.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: json));
  }

  Future<void> _clearEvaluation() async {
    final bool? clear = await _overSheet(
      () => showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('Clear evaluation records?'),
          content: const Text(
            'This removes the local command evaluation records from this phone.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Clear'),
            ),
          ],
        ),
      ),
    );
    if (clear == true) await _c.evaluation?.clear();
  }

  void _onController() {
    if (_c.listening) {
      if (_input.text != _c.partial) _input.text = _c.partial;
    } else if (_wasListening) {
      _input.clear();
    }
    _wasListening = _c.listening;
    final int confirms = _c.messages
        .where(
          (CopilotMessage m) => m.command?.state == CopilotCommandState.pending,
        )
        .length;
    if (confirms > _pendingConfirms && widget.screen != null && _expanded) {
      setState(() => _expanded = false);
    }
    _pendingConfirms = confirms;
    final int items = _c.messages.length + (_c.busy ? 1 : 0);
    if (items != _shownItems) {
      _shownItems = items;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _ask(String text) {
    _focus.unfocus();
    _c.ask(text);
  }

  void _submit() {
    final String text = _input.text.trim();
    if (text.isEmpty || _c.busy || _c.listening) return;
    _input.clear();
    _ask(text);
  }

  Future<void> _onMic() async {
    if (_c.listening) {
      await _c.cancelListening();
      return;
    }
    if (_c.busy) return;
    _focus.unfocus();
    if (!_c.micIntroSeen) {
      final bool? allowed = await _overSheet(
        () => showModalBottomSheet<bool>(
          context: context,
          builder: (_) => const _MicIntroSheet(),
        ),
      );
      if (!mounted) return;
      if (allowed != true) {
        _c.speechUnavailable();
        return;
      }
      _c.markMicIntroSeen();
    }
    await _c.startListening();
  }

  @override
  Widget build(BuildContext context) {
    _c.online =
        context.watch<ConnectivityProvider>().isOnline &&
        !context.watch<AuthProvider>().isOfflineVerified;
    final bool keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final double height =
        MediaQuery.sizeOf(context).height *
        (_expanded || keyboardOpen ? 0.94 : 0.66);
    return SizedBox(height: height, child: _sheet(context, keyboardOpen));
  }

  Widget _sheet(BuildContext context, bool keyboardOpen) {
    return PopScope(
      canPop: !keyboardOpen,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _focus.unfocus();
      },
      child: Scaffold(
        backgroundColor: _surface,
        resizeToAvoidBottomInset: true,
        body: ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[_c, _focus, _input]),
          builder: (BuildContext context, _) {
            final bool compact = !_expanded || _focus.hasFocus || keyboardOpen;
            return Column(
              children: <Widget>[
                _topBar(context),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _focus.unfocus,
                    child: _c.isEmpty
                        ? _Hero(compact: compact)
                        : _Chat(
                            controller: _c,
                            scroll: _scroll,
                            onOpen: _open,
                            onRetry: _c.retry,
                          ),
                  ),
                ),
                if (_c.suggestions.isNotEmpty)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: _Suggestions(
                      suggestions: _c.suggestions,
                      first: _c.isEmpty,
                      onPick: _ask,
                    ),
                  ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _inputBox(context),
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
                          child: Text(
                            'Scout can make mistakes. Double-check its answers.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: kCopilotMute),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    return DecoratedBox(
      decoration: kCopilotBarDecoration,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              color: kCopilotDeepGreen.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          CopilotBarRow(
            left: IconButton(
              tooltip: 'Close Scout',
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              onPressed: _close,
              icon: const Icon(Icons.close, color: kCopilotDeepGreen),
            ),
            center: const CopilotGlassPill(
              label: 'Scout',
              beta: true,
              semanticsLabel: 'Scout beta',
            ),
            right: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (!kReleaseMode && _c.evaluation != null) ...<Widget>[
                  IconButton(
                    tooltip: 'Copy evaluation records',
                    onPressed: _copyEvaluation,
                    icon: const Icon(Icons.data_object),
                    color: kCopilotDeepGreen,
                  ),
                  IconButton(
                    tooltip: 'Clear evaluation records',
                    onPressed: _clearEvaluation,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    color: kCopilotDeepGreen,
                  ),
                ],
                IconButton(
                  tooltip: _expanded ? 'Shrink Scout' : 'Expand Scout',
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded
                        ? Icons.close_fullscreen_rounded
                        : Icons.open_in_full_rounded,
                  ),
                  color: kCopilotDeepGreen,
                ),
                IconButton(
                  tooltip: 'New chat',
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  onPressed: _c.isEmpty ? null : _c.newChat,
                  icon: const Icon(Icons.edit_outlined),
                  color: kCopilotDeepGreen,
                  disabledColor: kCopilotDeepGreen.withValues(alpha: 0.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _inputBox(BuildContext context) {
    final int length = _input.text.length;
    final bool canSend = _input.text.trim().isNotEmpty && !_c.busy;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _focus.hasFocus ? kCopilotGreen : _fieldLine),
        boxShadow: _focus.hasFocus
            ? const <BoxShadow>[
                BoxShadow(color: Color(0x292F6F4F), spreadRadius: 3),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_c.listening)
            Padding(
              padding: const EdgeInsets.only(right: 6, bottom: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _c.preparing ? 'Getting ready…' : 'Listening…',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1B4F37),
                      ),
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _c.cancelListening,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kCopilotGreen,
                      side: const BorderSide(color: kCopilotGreen),
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: const StadiumBorder(),
                    ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: TextField(
              controller: _input,
              focusNode: _focus,
              readOnly: _c.listening,
              maxLength: _maxLength,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(),
              style: const TextStyle(fontSize: 14, color: kCopilotInk),
              decoration: const InputDecoration(
                hintText: 'Ask or say a command',
                hintStyle: TextStyle(color: Color(0xFF5F6D65)),
                counterText: '',
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.fromLTRB(0, 4, 0, 8),
              ),
            ),
          ),
          Row(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Text(
                  length >= 180 ? '$length / $_maxLength' : '',
                  style: TextStyle(
                    fontSize: 12,
                    color: length >= 190 ? _errorRed : kCopilotMute,
                    fontWeight: length >= 190
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
              const Spacer(),
              _MicButton(listening: _c.listening, onTap: _onMic),
              _SendButton(enabled: canSend, onTap: _submit),
            ],
          ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final String name =
        (context.watch<AuthProvider>().user?.name.trim().split(' ').first ?? '')
            .trim();
    final DateTime now = DateTime.now();
    final String greeting = overviewGreetingFor(now);
    final String who = name.isEmpty ? 'there' : name;
    final Widget text = compact
        ? Text(
            '$greeting, $who.',
            maxLines: 1,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: kCopilotInk,
            ),
          )
        : Text.rich(
            TextSpan(
              text: '$greeting,\n',
              children: <InlineSpan>[
                TextSpan(
                  text: '$who.',
                  style: const TextStyle(color: kCopilotGreen),
                ),
              ],
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 30,
              height: 1.15,
              letterSpacing: -0.4,
              fontWeight: FontWeight.w700,
              color: kCopilotInk,
            ),
          );
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, compact ? 8 : 24),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (!compact)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    DateFormat('EEEE, d MMMM').format(now),
                    style: const TextStyle(fontSize: 13, color: kCopilotMute),
                  ),
                ),
              text,
              if (!compact)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    kBasicEdition
                        ? 'Ask about your route and orders.'
                        : 'Ask about your route, orders and visit briefs.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: kCopilotMute),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chat extends StatelessWidget {
  const _Chat({
    required this.controller,
    required this.scroll,
    required this.onOpen,
    required this.onRetry,
  });

  final MobileCopilotController controller;
  final ScrollController scroll;
  final void Function(CopilotDestination destination) onOpen;
  final Future<void> Function(int errorIndex) onRetry;

  @override
  Widget build(BuildContext context) {
    final List<CopilotMessage> messages = controller.messages;
    return ListView.builder(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      itemCount: messages.length + (controller.busy ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (index == messages.length) return const _TypingDots();
        final CopilotMessage message = messages[index];
        switch (message.kind) {
          case CopilotMessageKind.user:
            return _UserBubble(message.text);
          case CopilotMessageKind.error:
            return _ErrorCard(
              notice: message.notice,
              onRetry: () => onRetry(index),
            );
          case CopilotMessageKind.answer:
            return _AnswerCard(message.answer!, onOpen: onOpen);
          case CopilotMessageKind.confirm:
            final CopilotPendingCommand command = message.command!;
            return _ConfirmCard(
              command: command,
              onConfirm: () => controller.confirmCommand(command),
              onCancel: () => controller.cancelCommand(command),
              busy: controller.busy,
            );
        }
      },
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8, left: 40),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: const BoxDecoration(
          color: kCopilotGreen,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(3),
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(fontSize: 14, color: Colors.white),
        ),
      ),
    );
  }
}

class _AnswerCard extends StatelessWidget {
  const _AnswerCard(this.answer, {required this.onOpen});

  final CopilotAnswer answer;
  final void Function(CopilotDestination destination) onOpen;

  @override
  Widget build(BuildContext context) {
    final CopilotDestination? destination = answer.open;
    final bool refused = answer.refused;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8, right: 24),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: refused ? const Color(0xFFFFF3E2) : Colors.white,
            border: Border.all(
              color: refused ? const Color(0xFFD9A05A) : _line,
            ),
            borderRadius: refused
                ? BorderRadius.circular(10)
                : const BorderRadius.only(
                    topLeft: Radius.circular(14),
                    topRight: Radius.circular(14),
                    bottomLeft: Radius.circular(3),
                    bottomRight: Radius.circular(14),
                  ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                answer.text,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: refused ? const Color(0xFF8F4B00) : kCopilotInk,
                ),
              ),
              for (final String line in answer.details)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    line,
                    style: const TextStyle(fontSize: 13, color: kCopilotMute),
                  ),
                ),
              if (destination != null && answer.openLabel.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: TextButton(
                    onPressed: () => onOpen(destination),
                    style: TextButton.styleFrom(
                      foregroundColor: kCopilotGreen,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 44),
                      alignment: Alignment.centerLeft,
                    ),
                    child: Text(answer.openLabel),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConfirmCard extends StatelessWidget {
  const _ConfirmCard({
    required this.command,
    required this.onConfirm,
    required this.onCancel,
    required this.busy,
  });

  final CopilotPendingCommand command;
  final VoidCallback onConfirm;

  final bool busy;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final CopilotCommandState state = command.state;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8, right: 24),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _line),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              command.prompt,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: kCopilotInk,
              ),
            ),
            const SizedBox(height: 8),
            if (state == CopilotCommandState.pending)
              Row(
                children: <Widget>[
                  FilledButton(
                    onPressed: busy ? null : onConfirm,
                    style: FilledButton.styleFrom(
                      backgroundColor: kCopilotGreen,
                      minimumSize: const Size(0, 44),
                      shape: const StadiumBorder(),
                    ),
                    child: const Text('Confirm'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: onCancel,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kCopilotGreen,
                      side: const BorderSide(color: kCopilotGreen),
                      minimumSize: const Size(0, 44),
                      shape: const StadiumBorder(),
                    ),
                    child: const Text('Cancel'),
                  ),
                ],
              )
            else if (state == CopilotCommandState.running)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: kCopilotGreen,
                ),
              )
            else
              Row(
                children: <Widget>[
                  Icon(
                    state == CopilotCommandState.done
                        ? Icons.check_circle_outline
                        : Icons.info_outline,
                    size: 16,
                    color: state == CopilotCommandState.done
                        ? kCopilotGreen
                        : kCopilotMute,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      command.note,
                      style: const TextStyle(fontSize: 13, color: kCopilotMute),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.notice, required this.onRetry});

  final String notice;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final bool limitReached =
        notice == CopilotServerFailure.personLimit.message ||
        notice == CopilotServerFailure.companyLimit.message ||
        notice == CopilotServerFailure.salespeopleLimit.message ||
        notice == CopilotServerFailure.requestRefused.message ||
        notice == CopilotServerFailure.signIn.message ||
        notice == CopilotServerFailure.noAccess.message;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8, right: 24),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFFDECEA),
            border: Border.all(color: const Color(0xFFE0A39D)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                notice.isEmpty ? 'Could not reach the server' : notice,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _errorRed,
                ),
              ),
              Text(
                notice == CopilotServerFailure.offline.message
                    ? 'Check your connection. Route and order questions still work.'
                    : limitReached
                    ? 'Route and order questions still work.'
                    : 'Try again in a moment. Route and order questions still work.',
                style: TextStyle(fontSize: 13, color: kCopilotInk),
              ),
              if (!limitReached) const SizedBox(height: 6),
              if (!limitReached)
                OutlinedButton(
                  onPressed: onRetry,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _errorRed,
                    backgroundColor: Colors.white,
                    side: const BorderSide(color: _errorRed),
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: const StadiumBorder(),
                  ),
                  child: const Text(
                    'Retry',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _anim.stop();
    } else if (!_anim.isAnimating) {
      _anim.repeat();
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Scout is thinking',
      excludeSemantics: true,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _line),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              topRight: Radius.circular(14),
              bottomLeft: Radius.circular(3),
              bottomRight: Radius.circular(14),
            ),
          ),
          child: AnimatedBuilder(
            animation: _anim,
            builder: (BuildContext context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (int i = 0; i < 3; i++)
                  Padding(
                    padding: EdgeInsets.only(right: i < 2 ? 4 : 0),
                    child: Opacity(
                      opacity:
                          0.45 +
                          0.55 *
                              (0.5 +
                                  0.5 *
                                      math.sin(
                                        (_anim.value - i * 0.15) * 2 * math.pi,
                                      )),
                      child: const SizedBox(
                        width: 7,
                        height: 7,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0xFF7B8A82),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DragAnywhere extends MaterialScrollBehavior {
  const _DragAnywhere();

  @override
  Set<PointerDeviceKind> get dragDevices => <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.trackpad,
  };
}

class _Suggestions extends StatelessWidget {
  const _Suggestions({
    required this.suggestions,
    required this.first,
    required this.onPick,
  });

  final List<String> suggestions;
  final bool first;
  final void Function(String text) onPick;

  @override
  Widget build(BuildContext context) {
    final int split = (suggestions.length + 1) ~/ 2;
    final List<List<String>> rows = <List<String>>[
      suggestions.sublist(0, split),
      if (split < suggestions.length) suggestions.sublist(split),
    ];
    final String label = first ? 'Try asking' : 'Next, you could ask';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Semantics(
            label: label,
            excludeSemantics: true,
            child: Text(
              label.toUpperCase(),
              style: const TextStyle(
                fontSize: 12,
                letterSpacing: 0.5,
                color: kCopilotMute,
              ),
            ),
          ),
        ),
        ScrollConfiguration(
          behavior: const _DragAnywhere(),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (int r = 0; r < rows.length; r++)
                  Padding(
                    padding: EdgeInsets.only(top: r == 0 ? 0 : 8),
                    child: Row(
                      children: <Widget>[
                        for (final String s in rows[r])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _SuggestionPill(s, onTap: () => onPick(s)),
                          ),
                      ],
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

class _SuggestionPill extends StatelessWidget {
  const _SuggestionPill(this.text, {required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: text,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: _fieldLine),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13),
              child: Center(
                widthFactor: 1,
                child: Text(
                  text,
                  softWrap: false,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: kCopilotInk,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.label,
    required this.onTap,
    required this.child,
    required this.fill,
    required this.border,
    this.shadow,
  });

  final String label;
  final VoidCallback? onTap;
  final Widget child;
  final Color fill;
  final Color border;
  final List<BoxShadow>? shadow;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fill,
                border: Border.all(color: border, width: 1.5),
                boxShadow: shadow,
              ),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _RoundAction(
      label: 'Send',
      onTap: enabled ? onTap : null,
      fill: enabled ? kCopilotGreen : const Color(0xFFC5D3CA),
      border: enabled ? kCopilotGreen : const Color(0xFFC5D3CA),
      child: const Icon(Icons.arrow_upward, size: 18, color: Colors.white),
    );
  }
}

class _MicButton extends StatefulWidget {
  const _MicButton({required this.listening, required this.onTap});

  final bool listening;
  final VoidCallback onTap;

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  void _sync() {
    final bool animate =
        widget.listening && !MediaQuery.disableAnimationsOf(context);
    if (animate && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!animate && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_MicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (BuildContext context, _) => _RoundAction(
        label: widget.listening ? 'Stop listening' : 'Speak',
        onTap: widget.onTap,
        fill: widget.listening ? kCopilotGreen : Colors.white,
        border: kCopilotGreen,
        shadow: widget.listening
            ? <BoxShadow>[
                BoxShadow(
                  color: const Color(0x2E2F6F4F),
                  spreadRadius: 7 * _pulse.value,
                ),
              ]
            : null,
        child: Icon(
          Icons.mic_none,
          size: 18,
          color: widget.listening ? Colors.white : kCopilotGreen,
        ),
      ),
    );
  }
}

class _MicIntroSheet extends StatelessWidget {
  const _MicIntroSheet();

  @override
  Widget build(BuildContext context) {
    ButtonStyle style({required bool primary}) => OutlinedButton.styleFrom(
      foregroundColor: primary ? Colors.white : kCopilotGreen,
      backgroundColor: primary ? kCopilotGreen : Colors.white,
      side: const BorderSide(color: kCopilotGreen),
      minimumSize: const Size(0, 44),
      shape: const StadiumBorder(),
      textStyle: const TextStyle(fontWeight: FontWeight.w600),
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Allow the microphone?',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              "Scoot Sales uses your phone's speech recognition only after you "
              'tap the mic. No audio is saved.',
              style: TextStyle(fontSize: 14, color: kCopilotMute),
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    style: style(primary: false),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Not now'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    style: style(primary: true),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Allow'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
