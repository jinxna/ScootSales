library;

import '../../models/retailer_priority_ranking.dart';
import 'copilot_entity_resolver.dart';
import 'order_search_session.dart';

class RankWhyCard {
  const RankWhyCard({required this.title, required this.steps});
  final String title;
  final List<String> steps;
  String get note => rankingScoreNote;
}

List<RetailerPriorityRanking> _newestPerSalesperson(
  List<RetailerPriorityRanking> visible,
) {
  final Map<String, RetailerPriorityRanking> newest =
      <String, RetailerPriorityRanking>{};
  for (final RetailerPriorityRanking row in visible) {
    final RetailerPriorityRanking? pick = RetailerPriorityRanking.newestActive(
      visible,
      salesmanUid: row.salesmanUid,
      salesmanCode: row.salesmanCode,
    );
    if (pick != null) newest['${pick.rankingId}|${pick.scopeKey}'] = pick;
  }
  return newest.values.toList(growable: false);
}

String _who(RetailerPriorityRanking ranking) => ranking.salesmanCode.isNotEmpty
    ? 'salesperson ${ranking.salesmanCode}'
    : 'its salesperson';

String _percent(double p) => '${(p * 100).toStringAsFixed(p < 0.1 ? 1 : 0)}%';

CopilotReply explainRetailerRank(
  String spoken,
  List<RetailerPriorityRanking> visible,
) {
  final List<RetailerPriorityRanking> rankings = _newestPerSalesperson(visible);
  if (rankings.isEmpty) {
    return const CopilotReply(
      'No retailer ranking is published for the salespeople you can see yet, '
      'so there is no rank to explain.',
    );
  }
  final Map<String, EntityRef> pool = <String, EntityRef>{};
  for (final RetailerPriorityRanking ranking in rankings) {
    for (final RankedRetailerOpportunity row in ranking.ranking) {
      if (row.retailerId.trim().isEmpty) continue;
      pool.putIfAbsent(
        row.retailerId,
        () => EntityRef(
          kind: EntityKind.retailer,
          id: row.retailerId,
          name: row.retailerName,
        ),
      );
    }
  }
  final String id;
  switch (resolveEntity(spoken, pool.values)) {
    case None():
      return CopilotReply(
        '"$spoken" is not in the current ranking of the salespeople you can '
        'see.',
      );
    case Many(:final List<EntityRef> entities):
      return CopilotReply(
        'Several ranked retailers match "$spoken": '
        '${entities.map((EntityRef e) => e.name).join(', ')}. '
        'Say the full name.',
      );
    case One(:final EntityRef entity):
      id = entity.id;
  }

  final List<(RetailerPriorityRanking, RankedRetailerOpportunity)> found =
      <(RetailerPriorityRanking, RankedRetailerOpportunity)>[
        for (final RetailerPriorityRanking ranking in rankings)
          for (final RankedRetailerOpportunity row in ranking.ranking)
            if (row.retailerId == id) (ranking, row),
      ]..sort(
        (
          (RetailerPriorityRanking, RankedRetailerOpportunity) a,
          (RetailerPriorityRanking, RankedRetailerOpportunity) b,
        ) => a.$2.rank.compareTo(b.$2.rank),
      );
  final (RetailerPriorityRanking ranking, RankedRetailerOpportunity row) =
      found.first;

  final String selection = !row.chosen
      ? 'It is ranked but not selected for this week.'
      : row.isExploration
      ? 'It is an exploration pick: the policy drew it from the score band '
            'near the cut-off, with a selection probability of '
            '${_percent(row.selectionProbability)}.'
      : 'The policy selected it on its score.';
  final String others = found.length < 2
      ? ''
      : ' It is also ranked for ${found.skip(1).map(((RetailerPriorityRanking, RankedRetailerOpportunity) f) => '${_who(f.$1)} (#${f.$2.rank})').join(', ')}.';
  final List<String> steps = rankingScoreSteps(row);
  final String head =
      '${row.retailerName} is #${row.rank} of ${ranking.ranking.length} for '
      '${_who(ranking)} in week ${ranking.weekKey}. $selection';
  if (steps.isEmpty) {
    return CopilotReply(
      '$head The ranking stores no score breakdown for this retailer. Its '
      'value is RM${row.opportunityPerRouteDay.toStringAsFixed(2)} per '
      'route-day.$others',
    );
  }
  return CopilotReply(
    '$head$others',
    card: RankWhyCard(
      title: 'Why ${row.retailerName} is #${row.rank}',
      steps: steps,
    ),
  );
}
