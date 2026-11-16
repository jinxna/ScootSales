import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/retailer_priority_ranking.dart';
import 'package:flutter_web_app/services/visit_priority_service.dart';

import 'fixtures/retailer_priority_ranking_runner_output.dart';

void main() {
  late Map<String, dynamic> document;

  setUpAll(() {
    document =
        jsonDecode(retailerPriorityRankingRunnerOutput) as Map<String, dynamic>;
  });

  RetailerPriorityRanking parse() {
    return parsePriorityRankings(<Map<String, dynamic>>[document]).single;
  }

  test('the document the runner writes parses into the read model', () {
    final RetailerPriorityRanking ranking = parse();
    expect(ranking.rankingId, 'rank_30109e23d9cafc9d2d670141');
    expect(ranking.scopeKey, 'ai1_demo_salesman');
    expect(ranking.salesmanUid, 'ai1_demo_salesman');
    expect(ranking.salesmanCode, 'AI1-S001');
    expect(ranking.branchId, 'AI1-B001');
    expect(ranking.weekKey, '2026-W38');
    expect(ranking.status, 'active');
    expect(ranking.policyVersion, 'route-opportunity/1.0.0');
    expect(ranking.rankingVersion, 'retailer-ranking/1.0.0');
    expect(ranking.expectedOrderValueVersion, 'expected-order-value/1.0.0');
    expect(ranking.coverageBasis, 'last_observed_order');
    expect(ranking.targetSize, 3);
    expect(ranking.retailerCount, 3);
    expect(ranking.chosenCount, 3);
    expect(ranking.generatedAt, isNotNull);
    expect(ranking.ranking, hasLength(3));
    expect(ranking.decisionLog, hasLength(3));
  });

  test('the RM/day objective and its inputs survive the round trip', () {
    final RetailerPriorityRanking ranking = parse();
    final RankedRetailerOpportunity top = ranking.ranking.first;
    expect(top.rank, 1);
    expect(top.chosen, isTrue);
    expect(top.exploitOrExplore, 'exploit');
    expect(top.selectionProbability, 1.0);
    expect(top.expectedOrderValueRm, closeTo(343.0374, 0.0001));
    expect(top.opportunityPerRouteDay, closeTo(8483.6544, 0.0001));
    expect(top.routeTimeDays, greaterThan(0));
    expect(top.travelMinutes, greaterThan(0));
    expect(top.serviceMinutes, 20);
    expect(top.daysSinceLastVisit, 11);
    expect(top.coverageBasis, 'last_observed_order');
    expect(top.forecastPairCount, 3);
    expect(top.observedBaselinePairCount, 0);
    for (final RankedRetailerOpportunity row in ranking.ranking) {
      expect(row.opportunityPerRouteDay, greaterThanOrEqualTo(0));
      expect(row.retailerName, isNotEmpty);
    }
  });

  test(
    'every considered retailer keeps the fields a decision is replayed from',
    () {
      final RetailerPriorityRanking ranking = parse();
      final Set<String> ranked = ranking.ranking
          .map((RankedRetailerOpportunity row) => row.retailerId)
          .toSet();
      final Set<String> logged = ranking.decisionLog
          .map((PriorityDecisionEntry entry) => entry.candidate)
          .toSet();
      expect(logged, ranked);
      for (final PriorityDecisionEntry entry in ranking.decisionLog) {
        expect(entry.candidate, isNotEmpty);
        expect(entry.policyVersion, 'route-opportunity/1.0.0');
        expect(entry.rank, greaterThan(0));
        expect(entry.score, greaterThanOrEqualTo(0));
        expect(entry.selectionProbability, inInclusiveRange(0, 1));
        expect(entry.exploitOrExplore, anyOf('exploit', 'explore'));
        expect(entry.chosen, isTrue);
      }
    },
  );
}
