import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../../models/user_profile.dart';
import '../../../../services/home_decisions_service.dart';
import '../../../../widgets/shop_panel.dart';
import 'home_parts.dart';

class HomeDecisionsCard extends StatefulWidget {
  const HomeDecisionsCard({
    super.key,
    required this.currentUser,
    required this.title,
    required this.onNavigate,
    this.service,
  });

  final UserProfile currentUser;
  final String title;
  final ValueChanged<String> onNavigate;
  final HomeDecisionsService? service;

  @override
  State<HomeDecisionsCard> createState() => _HomeDecisionsCardState();
}

class _HomeDecisionsCardState extends State<HomeDecisionsCard> {
  late Future<HomeDecisionResult> _future = _load();

  Future<HomeDecisionResult> _load() =>
      (widget.service ?? HomeDecisionsService()).load(widget.currentUser);

  void _retry() => setState(() => _future = _load());

  String _actionLabel(HomeDecision decision) {
    switch (decision.kind) {
      case HomeDecisionKind.routesNotPlanned:
        return 'Open planner';
      case HomeDecisionKind.followUpsDue:
      case HomeDecisionKind.followUpOverdue:
      case HomeDecisionKind.stopsWithoutReason:
        return 'Open visits';
      case HomeDecisionKind.pinsNotVerified:
        return decision.pageKey.isEmpty ? 'Open shop' : 'Check pins';
      case HomeDecisionKind.stoppedOrdering:
        return decision.retailerId.isEmpty ? 'Open shop list' : 'Open shop';
    }
  }

  void _open(HomeDecision decision) {
    if (decision.pageKey.isNotEmpty) {
      widget.onNavigate(decision.pageKey);
      return;
    }
    if (decision.retailerId.isNotEmpty) {
      showShopPanel(
        context,
        currentUser: widget.currentUser,
        retailerId: decision.retailerId,
        retailerName: decision.retailerName,
        focusProductId: decision.productId.isEmpty ? null : decision.productId,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScootCard(
      title: widget.title,
      child: FutureBuilder<HomeDecisionResult>(
        future: _future,
        builder:
            (
              BuildContext context,
              AsyncSnapshot<HomeDecisionResult> snapshot,
            ) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const HomeRowSkeletons(rows: 3);
              }
              final HomeDecisionResult? result = snapshot.data;
              if (snapshot.hasError || result == null) {
                return ScootErrorState(onRetry: _retry);
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (result.failed.isNotEmpty) _errorLine(result.failed),
                  if (result.incomplete.isNotEmpty)
                    _incompleteLine(result.incomplete),
                  if (result.decisions.isEmpty &&
                      result.failed.isEmpty &&
                      result.incomplete.isEmpty)
                    const ScootEmptyState(
                      title: 'Nothing needs a decision this week',
                      message: 'New items appear here as they come up.',
                      icon: ScootIcons.success,
                    )
                  else
                    HomeDivided(
                      children: <Widget>[
                        for (final HomeDecision decision in result.decisions)
                          _row(context, decision),
                      ],
                    ),
                ],
              );
            },
      ),
    );
  }

  Widget _errorLine(List<String> failed) {
    final ScootColors c = ScootColors.of(context);
    final Color danger = c.tone(ScootTone.danger).foreground;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        key: const ValueKey<String>('home-decisions-error'),
        children: <Widget>[
          Icon(Icons.error_outline, size: 16, color: danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Could not read: ${failed.join(', ')}. This list may be incomplete.',
              style: ScootType.body.copyWith(color: danger),
            ),
          ),
          TextButton(onPressed: _retry, child: const Text('Try again')),
        ],
      ),
    );
  }

  Widget _incompleteLine(List<String> incomplete) {
    final ScootColors c = ScootColors.of(context);
    final Color danger = c.tone(ScootTone.danger).foreground;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        key: const ValueKey<String>('home-decisions-incomplete'),
        children: <Widget>[
          Icon(Icons.error_outline, size: 16, color: danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Could not check all ${incomplete.join(', ')} this week.',
              style: ScootType.body.copyWith(color: danger),
            ),
          ),
          TextButton(onPressed: _retry, child: const Text('Try again')),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, HomeDecision decision) {
    final ScootColors c = ScootColors.of(context);
    final bool openable =
        decision.pageKey.isNotEmpty || decision.retailerId.isNotEmpty;
    return Padding(
      key: ValueKey<String>('home-decision-${decision.kind.name}'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final Widget sentence = InkWell(
            onTap: openable ? () => _open(decision) : null,
            child: Text(
              decision.text,
              style: ScootType.bodyStrong.copyWith(color: c.ink),
            ),
          );
          final Widget action = HomeRowAction(
            label: _actionLabel(decision),
            onPressed: openable ? () => _open(decision) : null,
          );
          final Widget badge = Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.tone(ScootTone.warning).background,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: ExcludeSemantics(
              child: Text(
                '${decision.count}',
                style: ScootType.bodyStrong.copyWith(
                  color: c.tone(ScootTone.warning).foreground,
                ),
              ),
            ),
          );
          if (box.maxWidth < 420) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    badge,
                    const SizedBox(width: 12),
                    Expanded(child: sentence),
                  ],
                ),
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerLeft, child: action),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              badge,
              const SizedBox(width: 14),
              Expanded(child: sentence),
              const SizedBox(width: 12),
              action,
            ],
          );
        },
      ),
    );
  }
}
