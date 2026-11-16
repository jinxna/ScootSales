import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/dso_colors.dart';
import 'copilot_status.dart';
import 'copilot_widgets.dart';

class CopilotTrigger extends StatefulWidget {
  const CopilotTrigger({
    super.key,
    required this.onPressed,
    required this.status,
    this.compact = false,
    this.open = false,
  });

  final VoidCallback onPressed;
  final ValueListenable<CopilotServerState> status;
  final bool compact;

  final bool open;

  @override
  State<CopilotTrigger> createState() => _CopilotTriggerState();
}

class _CopilotTriggerState extends State<CopilotTrigger> {
  final GlobalKey _buttonKey = GlobalKey();

  final FocusNode _focus = FocusNode(debugLabel: 'copilot trigger');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _press() {
    _focus.requestFocus();
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final bool compact = widget.compact;
    final bool open = widget.open;
    final DsoColors dso = context.dso;
    return ValueListenableBuilder<CopilotServerState>(
      valueListenable: widget.status,
      builder: (BuildContext context, CopilotServerState state, _) {
        final Color? dot = copilotStatusColor(dso, state);
        final Widget mark = CopilotMark(size: compact ? 22 : 20);
        final Widget content = compact
            ? Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  mark,
                  if (dot != null)
                    Positioned(
                      right: -4,
                      top: -4,
                      child: StatusDot(color: dot, size: 11, ring: dso.card),
                    ),
                ],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  mark,
                  const SizedBox(width: 8),
                  Text(
                    'Scout',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: dso.accentText,
                    ),
                  ),
                  if (dot != null) ...<Widget>[
                    const SizedBox(width: 8),
                    StatusDot(color: dot),
                  ],
                ],
              );
        final Widget button = KeyedSubtree(
          key: _buttonKey,
          child: Semantics(
            button: true,
            selected: open,
            label: 'Scout',
            value: copilotStatusText(state),
            excludeSemantics: true,
            onTap: _press,
            child: Material(
              color: open ? dso.brandSurface : dso.card,
              shape: StadiumBorder(
                side: BorderSide(color: open ? dso.accent : dso.hairline),
              ),
              child: InkWell(
                customBorder: const StadiumBorder(),
                focusNode: _focus,
                onTap: _press,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: 38,
                    minWidth: compact ? 38 : 0,
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 8 : 12,
                      vertical: 6,
                    ),
                    child: Center(
                      widthFactor: 1,
                      heightFactor: 1,
                      child: content,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        return open
            ? button
            : Tooltip(
                message: 'Scout · ${copilotStatusText(state)}',
                preferBelow: true,
                verticalOffset: 28,
                waitDuration: const Duration(milliseconds: 600),
                child: button,
              );
      },
    );
  }
}
