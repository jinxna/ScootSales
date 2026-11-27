import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/action_centre_item.dart';
import 'package:flutter_web_app/pages/admin/navigation/cms_navigation.dart';
import 'package:flutter_web_app/theme/dso_theme.dart';
import 'package:flutter_web_app/voice/copilot/copilot_controller.dart';
import 'package:flutter_web_app/voice/copilot/copilot_entity_resolver.dart';
import 'package:flutter_web_app/voice/copilot/copilot_grammar.dart';
import 'package:flutter_web_app/voice/copilot/copilot_page_request.dart';
import 'package:flutter_web_app/voice/copilot/copilot_widgets.dart';
import 'package:flutter_web_app/voice/copilot/order_search_session.dart';
import 'package:flutter_web_app/voice/dashboard_voice_catalog.dart';
import 'package:flutter_web_app/voice/dashboard_voice_parser.dart';
import 'package:flutter_web_app/voice/dashboard_voice_types.dart';

const String _users = 'user_directory';
const String _notUnderstood = 'not understood';
const String _calm =
    "I am here for questions about this company's orders, routes, shops and team. Try one of these.";

final List<DashboardVoicePage> _pages = dashboardVoicePagesFromCms(
  cmsSearchItems('admin'),
);

final List<DashboardVoicePage> _team = dashboardVoicePagesFromCms(
  cmsSearchItems('supervisor'),
);

const Set<String> _peoplePages = <String>{
  'user_directory',
  'my_team',
  'salesman_activity',
  'team_activity',
  'visit_logs',
};

String _route(String phrase) {
  final CopilotIntent? intent = interpretCopilot(phrase);
  if (intent is SmallTalkIntent) return 'scout ${intent.kind.name}';
  if (intent != null) return 'scout ${intent.runtimeType}';
  final String? parsed = const DashboardVoiceParser()
      .parse(phrase, _pages)
      .interpretation
      ?.pageKey;
  if (parsed != null) return 'open $parsed';
  final String? picked = copilotModelPage(phrase, _users, _pages)?.key;
  return picked == null ? _notUnderstood : 'open $picked';
}

OrderSearchSession _waitingOrders({Future<int> Function()? countWaiting}) =>
    OrderSearchSession(
      countWaiting: countWaiting,
      readWindow: (DateTime start, DateTime end) async => OrderWindow(
        rows: <Map<String, dynamic>>[
          for (int i = 1; i <= 3; i++)
            <String, dynamic>{
              'orderId': 'O$i',
              'status': 'submitted',
              'retailerName': 'Shop $i',
              'submittedAt': DateTime.utc(2026, 11, 10 + i),
              'totalAmount': 100.0,
            },
        ],
      ),
      loadSalespeople: () async => const [],
      download: (String filename, String csv) => true,
      recordExport: (set, filename) async {},
      scopeNote: null,
      clock: () => DateTime.utc(2026, 11, 15, 6),
    );

void main() {
  test(
    'a page opens only when the phrase names it; rude and random phrases never open one',
    () {
      const List<(String, String)> table = <(String, String)>[
        ('users', 'open $_users'),
        ('Users', 'open $_users'),
        ('user', 'open $_users'),
        ('open users', 'open $_users'),
        ('go to users', 'open $_users'),
        ('show me the users page', 'open $_users'),
        ('can you open the users page for me quickly', 'open $_users'),
        ('open notification apge', 'open notifications'),
        ('U ASS', 'scout chatter'),
        ('u ass', 'scout chatter'),
        ('stupid', 'scout chatter'),
        ('LOL', 'scout chatter'),
        ('you suck', 'scout chatter'),
        ('who is mark zuckerberg', 'scout offTopic'),
        ('us', _notUnderstood),
        ('use', _notUnderstood),
        ('user manual', _notUnderstood),
        ('usres', _notUnderstood),
        ('open usres', _notUnderstood),
        ("don't open users", _notUnderstood),
        ('users suck', _notUnderstood),
        ('open my ass', _notUnderstood),
        ('asdf qwer', _notUnderstood),
      ];
      final List<String> wrong = <String>[
        for (final (String phrase, String expected) in table)
          if (_route(phrase) != expected)
            '"$phrase": expected $expected, got ${_route(phrase)}',
      ];
      expect(wrong, isEmpty);
      expect(table.length, 23);
    },
  );

  test(
    'a model page pick is refused unless it is a known page the phrase asks for',
    () {
      expect(copilotModelPage('U ASS', _users, _pages), isNull);
      expect(copilotModelPage('open orders', _users, _pages), isNull);
      expect(copilotModelPage('open users', 'no_such_page', _pages), isNull);
      expect(copilotModelPage('open users', 42, _pages), isNull);
      expect(copilotModelPage('never open users', _users, _pages), isNull);
      expect(copilotModelPage('take me to users', _users, _pages)?.key, _users);
      expect(copilotModelPage('users page', _users, _pages)?.key, _users);
      expect(
        copilotModelPage(
          'somewhere to see what customers sent us',
          _users,
          _pages,
        ),
        isNull,
      );
      expect(copilotModelPage('show me your ass', _users, _pages), isNull);
      expect(
        copilotModelPage('i do not want to see that page', _users, _pages),
        isNull,
      );
      expect(
        copilotModelPage('this thing is really very bad', _users, _pages),
        isNull,
      );
      expect(copilotAsksForPlanner('U ASS'), isFalse);
      expect(copilotAsksForPlanner("don't plan anything"), isFalse);
      expect(
        copilotAsksForPlanner("bring up next week's schedule for her"),
        isTrue,
      );
    },
  );

  test('a model page pick needs words that point at that page', () {
    const List<String> rude = <String>[
      'go to hell you stupid bot',
      'open your eyes you dumb bot',
      'show me your worst joke please',
      'where is my money you fool',
      'take me to your leader now',
    ];
    final List<String> opened = <String>[
      for (final String phrase in rude)
        for (final DashboardVoicePage page in _pages)
          if (copilotModelPage(phrase, page.key, _pages) != null)
            '"$phrase" opened ${page.key}',
    ];
    expect(opened, isEmpty);
    expect(_pages.map((DashboardVoicePage p) => p.key), contains('all_orders'));
    expect(_pages.length, greaterThan(10));
    expect(
      copilotModelPage(
        'somewhere to see what customers sent us',
        'all_orders',
        _pages,
      )?.key,
      'all_orders',
    );
    expect(
      copilotModelPage('show users who never logged in', _users, _pages)?.key,
      _users,
    );
    expect(
      copilotModelPage(
        'show users who have not logged in',
        _users,
        _pages,
      )?.key,
      _users,
    );
  });

  test(
    "a phrase opens no page whatever page the model picks when it is rude, negated, or its object is not the dashboard's own thing (a word outside the dashboard, not after for, from, by, at or near)",
    () {
      const List<String> nothing = <String>[
        'U ASS',
        'go to hell you stupid bot',
        'show me your worst joke please',
        'what is the weather today',
        'asdf jkl',
        "don't open users or orders",
        'the orders page is so slow today',
        'i hate planning routes',
        'see you later team',
        'look, this plan is bad',
        'check when lunch is',
        'check when Ali is back',
        'users are confusing; do not open them',
        'open your eyes you dumb bot',
        'take me to your leader now',
        'open the pod bay doors hal',
        'can you find me a girlfriend',
        'check out this funny cat video',
        'where is my money you fool',
        'i do not see why you are so slow',
        'thanks for the route',
        'what a terrible week it was',
        'Ali will be away next week',
        'never take me to the users page',
        'no need to open the orders',
        "don't show all orders",
        'where did the team go for lunch',
        'check the weather for this week',
        'did you see the customer shouting just now',
        'people who like durian',
        "Don't automatically open users",
        'Show users who never show up',
        'staff party next week',
        'route to the airport',
        'my users are angry',
        'find a cheap flight for next week',
        'where can i buy durian',
        'list all the movies this week',
        'open the window please',
        'check my email',
        'orders of pizza are late',
        'the team won the football match',
        'users of facebook',
        'add sugar to my coffee',
        'who are you',
        'plan a holiday trip',
        'the shop next door sells durian',
        'my staff are on holiday today',
      ];
      final List<String> opened = <String>[
        for (final String phrase in nothing) ...<String>[
          for (final DashboardVoicePage page in _pages)
            if (copilotModelPage(phrase, page.key, _pages) != null)
              '"$phrase" opened ${page.key}',
          if (copilotAsksForPlanner(phrase)) '"$phrase" opened the planner',
          if (!copilotRefusesAnyPage(phrase))
            if (const DashboardVoiceParser()
                    .parse(phrase, _pages)
                    .interpretation
                    ?.pageKey
                case final String key)
              '"$phrase" opened $key without the model',
        ],
      ];
      expect(opened, isEmpty);
      expect(nothing.length, 48);
    },
  );

  test(
    'opens the page: head noun is a page noun, accepted (an off-topic request whose object is a page noun opens that page)',
    () {
      const List<(String, String)> accepted = <(String, String)>[
        ('find a shop near the airport', 'retailer'),
        ('show orders for pizza tonight', 'all_orders'),
        ('show me a good coffee shop near here', 'retailer'),
        ('show me a funny shop sign', 'retailer'),
        ('show me the staff party photos', _users),
        ('who ordered lunch', 'all_orders'),
      ];
      final List<String> wrong = <String>[
        for (final (String phrase, String picked) in accepted)
          if (copilotModelPage(phrase, picked, _pages)?.key != picked)
            '"$phrase" with $picked: got ${copilotModelPage(phrase, picked, _pages)?.key}',
      ];
      expect(wrong, isEmpty);
      expect(accepted.length, 6);
    },
  );

  test(
    "a request whose object is the picked page's own noun opens that page: list, show, open, find, add or change it, how do i, who are, which, or the bare noun with please, a time or a dashboard filter",
    () {
      const List<(String, String, String?)> table = <(String, String, String?)>[
        ('users', _users, _users),
        ('open all orders', 'all_orders', 'all_orders'),
        (
          'take me to the route planner please',
          'route_planner',
          'route_planner',
        ),
        ('show users who never logged in', _users, _users),
        ('find users who never logged in', _users, _users),
        ('find users who have not logged in', _users, _users),
        ('i wan see order not yet approve', 'all_orders', 'all_orders'),
        ('orders that are not approved', 'all_orders', 'all_orders'),
        ('where can i see the staff list', _users, _users),
        ('can u show me who is in my team', _users, _users),
        ('show me next week plan for Ali', 'route_planner', 'route_planner'),
        ('somewhere to see what customers sent us', 'all_orders', 'all_orders'),
        ('somewhere to see what customers sent us', _users, null),
        ('show the worst shops', 'retailer', 'retailer'),
        ('show the worst shops', _users, null),
        ('why would i open users', _users, _users),
        ('Can you show the worst shops?', 'retailer', 'retailer'),
        ('Can you show the worst shops?', _users, null),
        ('i need to add a new salesman', _users, _users),
        ('which shops have no location yet', 'retailer', 'retailer'),
        ('how do i change a user password', _users, _users),
        ('list all retailers', 'retailer', 'retailer'),
        ('who are my staff', _users, _users),
        ('orders pls', 'all_orders', 'all_orders'),
        ('orders from yesterday', 'all_orders', 'all_orders'),
        (
          'let me see the routes for next week',
          'route_planner',
          'route_planner',
        ),
        ('i want to check today orders', 'all_orders', 'all_orders'),
        ('pull up the retailer list', 'retailer', 'retailer'),
        ('show me orders for the coffee shop', 'all_orders', 'all_orders'),
        ('show me orders for the coffee shop', 'retailer', null),
        ('add a new shop', 'retailer', 'retailer'),
        ('who ordered today', 'all_orders', 'all_orders'),
        ('open the visit logs', 'visit_logs', 'visit_logs'),
        ('show me a list of shops', 'retailer', 'retailer'),
        ('users pls', _users, _users),
        ('find shops with no pin', 'retailer', 'retailer'),
        ('show orders waiting for approval', 'all_orders', 'all_orders'),
        ('which users have not logged in this week', _users, _users),
        ('who are the salespeople', _users, _users),
        ('how do i add a product', 'product', 'product'),
        ('remove a user', _users, _users),
        ('staff list please', _users, _users),
        ("next week's routes", 'route_planner', 'route_planner'),
        ('orders today', 'all_orders', 'all_orders'),
        ("can you pull up yesterday's orders", 'all_orders', 'all_orders'),
        ('change the route for Ali', 'route_planner', 'route_planner'),
        ("show ali's orders", 'all_orders', 'all_orders'),
        ('open forecast', 'prediction', 'prediction'),
        ('show the top shops this month', 'retailer', 'retailer'),
        ('shops with no location', 'retailer', 'retailer'),
        ('show overdue visits', 'visit_logs', 'visit_logs'),
        ('show unpaid orders', 'all_orders', 'all_orders'),
        ('show orders awaiting approval', 'all_orders', 'all_orders'),
        ('show orders worth more than 500', 'all_orders', 'all_orders'),
        ('show all orders since October', 'all_orders', 'all_orders'),
        ('show my inactive salesmen', _users, _users),
        ('show customers without orders this quarter', 'retailer', 'retailer'),
        ('please show the inventory', 'product', 'product'),
        ('show unvisited shops', 'retailer', 'retailer'),
        ('where do i approve orders', 'all_orders', 'all_orders'),
        ('i would like to see the sales report', 'reports', 'reports'),
        ('i would like to see the sales report', 'all_orders', null),
        ('what did Ali sell today', 'all_orders', 'all_orders'),
        ('show me which shops Ali visited', 'retailer', 'retailer'),
      ];
      final List<String> wrong = <String>[
        for (final (String phrase, String picked, String? expected) in table)
          if (copilotModelPage(phrase, picked, _pages)?.key != expected)
            '"$phrase" with $picked: expected $expected, got ${copilotModelPage(phrase, picked, _pages)?.key}',
      ];
      expect(wrong, isEmpty);
      expect(copilotAsksForPlanner('show me next week plan for Ali'), isTrue);
      expect(
        copilotAsksForPlanner('take me to the route planner please'),
        isTrue,
      );
    },
  );

  test(
    'request verbs compare, filter, export, sort, refresh, tell and need open the page their object names',
    () {
      const List<(String, String)> table = <(String, String)>[
        ('compare this month and last month sales', 'reports'),
        ('please filter orders', 'all_orders'),
        ('please export reports', 'reports'),
        ('sort orders by value', 'all_orders'),
        ('refresh inventory', 'product'),
        ('compare salesmen', _users),
        ('compare salesmen', 'salesman_activity'),
        ('can you tell me how my salesmen are doing', _users),
        ('can you tell me how my salesmen are doing', 'salesman_activity'),
        ('i need the stock list', 'product'),
      ];
      final List<String> wrong = <String>[
        for (final (String phrase, String picked) in table)
          if (copilotModelPage(phrase, picked, _pages)?.key != picked)
            '"$phrase" with $picked: got ${copilotModelPage(phrase, picked, _pages)?.key}',
      ];
      expect(wrong, isEmpty);
      expect(
        copilotModelPage('please filter orders', 'product', _pages),
        isNull,
      );
      expect(copilotModelPage('i need the stock list', _users, _pages), isNull);
    },
  );

  test(
    'question forms how much, is there, when can i, show me how and show me where open the page they ask about',
    () {
      const List<(String, String)> table = <(String, String)>[
        ('how much did we sell last month', 'reports'),
        ('how much did we sell last month', 'all_orders'),
        ('is there a report for returns', 'reports'),
        ('when can i see orders', 'all_orders'),
        ('show me how the team is doing', _users),
        ('show me where orders are', 'all_orders'),
      ];
      final List<String> wrong = <String>[
        for (final (String phrase, String picked) in table)
          if (copilotModelPage(phrase, picked, _pages)?.key != picked)
            '"$phrase" with $picked: got ${copilotModelPage(phrase, picked, _pages)?.key}',
      ];
      expect(wrong, isEmpty);
      expect(
        copilotModelPage(
          'show me how the team is doing',
          'my_team',
          _team,
        )?.key,
        'my_team',
      );
      expect(
        copilotModelPage('is there a report for returns', 'product', _pages),
        isNull,
      );
      expect(copilotModelPage('when is lunch', 'all_orders', _pages), isNull);
      expect(
        copilotModelPage('show me how to cook rice', 'product', _pages),
        isNull,
      );
    },
  );

  test(
    'page nouns sales, items, team and stock, and describing words like low, open the page they belong to',
    () {
      const List<(String, String)> table = <(String, String)>[
        ('low stock items', 'product'),
        ('how much did we sell last month', 'reports'),
        ('compare this month and last month sales', 'reports'),
        ('show me how the team is doing', _users),
      ];
      final List<String> wrong = <String>[
        for (final (String phrase, String picked) in table)
          if (copilotModelPage(phrase, picked, _pages)?.key != picked)
            '"$phrase" with $picked: got ${copilotModelPage(phrase, picked, _pages)?.key}',
      ];
      expect(wrong, isEmpty);
      expect(copilotModelPage('low stock items', 'all_orders', _pages), isNull);
    },
  );

  test(
    'a name opens only a page about people or activity, and a lower-case name counts only when a known salesperson has it',
    () {
      const List<String> known = <String>['Ali Hassan'];
      for (final String phrase in const <String>[
        'show me Ali today',
        'show me ali today',
        'show me where Ali is now',
        'show me where ali is now',
      ]) {
        expect(
          copilotModelPage(
            phrase,
            'salesman_activity',
            _pages,
            knownNames: known,
          )?.key,
          'salesman_activity',
          reason: phrase,
        );
      }
      expect(
        copilotModelPage('show me Ali today', 'salesman_activity', _pages),
        isNull,
      );
      expect(
        copilotModelPage('who is ali', _users, _pages, knownNames: known),
        isNull,
      );
      expect(
        copilotModelPage(
          'show me ali today',
          'salesman_activity',
          _pages,
          knownNames: known,
        )?.key,
        'salesman_activity',
      );
      expect(
        copilotModelPage('show me ali today', 'salesman_activity', _pages),
        isNull,
      );
      expect(
        copilotModelPage(
          'show me hassan today',
          'visit_logs',
          _pages,
          knownNames: known,
        )?.key,
        'visit_logs',
      );
      expect(
        copilotModelPage(
          'show me al today',
          'salesman_activity',
          _pages,
          knownNames: known,
        ),
        isNull,
      );
      final List<String> opened = <String>[
        for (final String phrase in const <String>[
          'open Netflix',
          'show me Ali today',
          'show me ali today',
        ])
          for (final DashboardVoicePage page in _pages)
            if (!_peoplePages.contains(page.key) &&
                copilotModelPage(phrase, page.key, _pages, knownNames: known) !=
                    null)
              '"$phrase" opened ${page.key}',
      ];
      expect(opened, isEmpty);
      expect(<String>[
        for (final DashboardVoicePage page in _pages)
          if (copilotModelPage('open Netflix', page.key, _pages) != null)
            page.key,
      ], isEmpty);
      expect(
        copilotModelPage('show me your worst orders', 'all_orders', _pages),
        isNull,
      );
    },
  );

  test(
    'a bare why explains the item again; a complaint about Scout does not',
    () {
      expect(interpretCopilot('why?'), isA<ExplainIntent>());
      expect(interpretCopilot('Why'), isA<ExplainIntent>());
      expect(
        interpretCopilot('why are you like this'),
        isNot(isA<ExplainIntent>()),
      );
      expect(interpretCopilot('why is this here'), isA<ExplainIntent>());
    },
  );

  test('the planner opens only for a planning request', () {
    const List<(String, bool)> table = <(String, bool)>[
      ('Ali will be away next week', false),
      ('what a terrible week it was', false),
      ('the route was stupid', false),
      ('plan next week for Aina', true),
      ('open the route planner', true),
      ("show Aina's schedule", true),
    ];
    final List<String> wrong = <String>[
      for (final (String phrase, bool expected) in table)
        if (copilotAsksForPlanner(phrase) != expected)
          '"$phrase": expected $expected',
    ];
    expect(wrong, isEmpty);
  });

  test('a question about work is never refused as off topic', () {
    const List<String> work = <String>[
      'who is working today',
      'who is online now',
      'who was late yesterday',
      'who created this order',
      'who created orders this week',
      'how old is the oldest pending order',
      'what is the date of the last order from emart',
    ];
    final List<String> refused = <String>[
      for (final String phrase in work)
        if (_route(phrase) == 'scout offTopic') phrase,
    ];
    expect(refused, isEmpty);
    expect(_route('who is mark zuckerberg'), 'scout offTopic');
  });

  test('a complaint with why is not read as a request to explain an item', () {
    expect(
      interpretCopilot('i do not see why you are so slow'),
      isNot(isA<ExplainIntent>()),
    );
    expect(interpretCopilot('why is item 2 here'), isA<ExplainIntent>());
    expect(interpretCopilot('explain this'), isA<ExplainIntent>());
  });

  test(
    'who is ali goes on to normal handling when Ali is a salesperson',
    () async {
      final CopilotController scout = CopilotController(
        allowed: true,
        orders: OrderSearchSession(
          readWindow: (DateTime start, DateTime end) async =>
              const OrderWindow(rows: <Map<String, dynamic>>[]),
          loadSalespeople: () async => const <EntityRef>[
            EntityRef(
              kind: EntityKind.salesperson,
              id: 'u1',
              name: 'Ali Hassan',
            ),
          ],
          download: (String filename, String csv) => true,
          recordExport: (set, filename) async {},
          scopeNote: null,
          clock: () => DateTime.utc(2026, 11, 15, 6),
        ),
        loadItems: () async => (
          items: const <ActionCentreItem>[],
          failedSources: const <String>[],
        ),
        readStatus: (_) async => 'new',
        writeStatus: (_, _, _) async => false,
        openPage: (String key) async => true,
      );
      expect(await scout.handle('who is ali'), isFalse);
      expect(await scout.handle('who is mark zuckerberg'), isTrue);
    },
  );

  test('ok answers neutrally and keeps a waiting confirmation', () async {
    final List<String> written = <String>[];
    final ActionCentreItem item = ActionCentreItem(
      id: 'a1',
      title: 'Shop A stopped buying',
      category: 'retailer',
      priority: 'high',
      reason: 'No order for 3 weeks.',
      recommendedAction: 'Visit the shop.',
      confidence: 'high',
      relatedPageKey: 'retailer',
      relatedEntityType: 'retailer',
      relatedEntityId: 'r1',
      createdAt: DateTime.utc(2026, 11, 14),
      source: 'weekly',
      status: 'new',
    );
    final CopilotController scout = CopilotController(
      allowed: true,
      loadItems: () async =>
          (items: <ActionCentreItem>[item], failedSources: const <String>[]),
      readStatus: (_) async => 'new',
      writeStatus:
          (ActionCentreItem target, String shown, String status) async {
            written.add('${target.id} $status');
            return true;
          },
      openPage: (String key) async => true,
      clock: () => DateTime.utc(2026, 11, 15, 6),
    );
    expect(await scout.handle('ok'), isTrue);
    expect(
      scout.entries.last.text,
      'Noted. Ask me when you need something else.',
    );
    await scout.handle('what needs my attention');
    await scout.handle('mark item 1 as in review');
    expect(scout.pending, isNotNull);
    await scout.handle('noted');
    expect(
      scout.entries.last.text,
      'Noted. Your request still waits. Say confirm or cancel.',
    );
    expect(scout.pending, isNotNull);
    await scout.handle('confirm');
    expect(written, <String>['a1 in_review']);
  });

  test(
    'small talk, questions Scout cannot answer and insults get one calm fixed line',
    () async {
      final List<String> opened = <String>[];
      final CopilotController scout = CopilotController(
        allowed: true,
        loadItems: () async => (
          items: const <ActionCentreItem>[],
          failedSources: const <String>[],
        ),
        readStatus: (_) async => 'new',
        writeStatus: (_, _, _) async => false,
        openPage: (String key) async {
          opened.add(key);
          return true;
        },
      );
      Future<String> say(String text) async {
        expect(await scout.handle(text), isTrue, reason: text);
        return scout.entries.last.text;
      }

      expect(
        await say('who is mark zuckerberg'),
        "I can only answer questions about this company's orders, routes, shops and team, so I cannot answer that. Try one of these.",
      );
      expect(await say('LOL'), _calm);
      expect(await say('stupid'), _calm);
      expect(await say('U ASS'), _calm);
      expect(
        await say('what can you even do bud'),
        startsWith('Here is what I can do.\n'),
      );
      expect(
        await say('what do you do'),
        startsWith('Here is what I can do.\n'),
      );
      expect(await say('help'), startsWith('Here is what I can do.\n'));
      expect(
        await say('hi'),
        "Hello. I answer questions about this company's orders, routes, shops and team. Try one of these.",
      );
      expect(
        await say('thanks'),
        'You are welcome. Ask me when you need something else.',
      );
      expect(
        await say('how are you doing'),
        startsWith('I am doing well, thanks.'),
      );
      expect(opened, isEmpty);
    },
  );

  test('a possessive name keeps its "\'s" when typos are folded', () {
    expect(
      interpretCopilot(
        "why is Choice Supermarket Tabuan Jaya on E2E Salesperson's route",
        now: DateTime.utc(2026, 11, 19, 6),
      ),
      isA<RouteWhyIntent>(),
    );
    expect(
      foldCommandTypos("appprove salesperson's route"),
      "approve salesperson's route",
    );
  });

  test(
    'typo folding repairs the approve verb and never rewrites a real word',
    () {
      expect(
        foldCommandTypos('appprove the pending order'),
        'approve the pending order',
      );
      expect(foldCommandTypos('aprove all of them'), 'approve all of them');
      expect(foldCommandTypos('apprve those orders'), 'approve those orders');
      for (final String word in <String>[
        'unassigned',
        'supervises',
        'supervised',
        'detailed',
        'retained',
        'resigned',
        'designed',
        'collected',
        'corrected',
        'converted',
        'resort',
        'approved',
        'approves',
        'approvals',
        'improve',
      ]) {
        final String phrase = 'show $word shops';
        expect(foldCommandTypos(phrase), phrase, reason: word);
      }
      final DateTime now = DateTime.utc(2026, 11, 19, 6);
      expect(
        interpretCopilot('who supervises jaylen ortiz', now: now),
        isA<TeamIntent>(),
      );
      expect(
        interpretCopilot('show unassigned shops', now: now),
        isNot(isA<ShopsOfPersonIntent>()),
      );
    },
  );

  test(
    '"approve those" offers only waiting orders among the rows on the card',
    () async {
      final List<String> approved = <String>[];
      final CopilotController scout = CopilotController(
        allowed: true,
        orders: OrderSearchSession(
          readWindow: (DateTime start, DateTime end) async => OrderWindow(
            rows: <Map<String, dynamic>>[
              for (int i = 1; i <= kOrderRowsShown + 2; i++)
                <String, dynamic>{
                  'orderId': 'O$i',
                  'status': i <= 2 ? 'submitted' : 'approved',
                  'retailerName': 'Shop $i',
                  'submittedAt': DateTime.utc(2026, 11, i),
                  'totalAmount': 100.0,
                },
            ],
          ),
          loadSalespeople: () async => const [],
          download: (String filename, String csv) => true,
          recordExport: (set, filename) async {},
          scopeNote: null,
          clock: () => DateTime.utc(2026, 11, 15, 6),
        ),
        approvals: OrderApprovalActions(
          canDecide: (Map<String, dynamic> o) => o['status'] == 'submitted',
          limitWarnings: (Map<String, dynamic> o) async => const <String>[],
          approve: (Map<String, dynamic> o) async {
            approved.add('${o['orderId']}');
            return null;
          },
        ),
        loadItems: () async => (
          items: const <ActionCentreItem>[],
          failedSources: const <String>[],
        ),
        readStatus: (_) async => 'new',
        writeStatus: (_, _, _) async => false,
        openPage: (String key) async => true,
        clock: () => DateTime.utc(2026, 11, 15, 6),
      );
      expect(await scout.handle('orders this month'), isTrue);
      expect(await scout.handle('approve those orders'), isTrue);
      expect(
        scout.entries.last.text,
        startsWith('0 of the orders shown wait for approval.'),
      );
      expect(scout.pending, isNull);
      await scout.handle('confirm');
      expect(approved, isEmpty);
    },
  );

  test(
    '"yeah approve it" after the waiting list asks to confirm; only Confirm within 60 seconds approves, skipping a product-limit order',
    () async {
      DateTime now = DateTime.utc(2026, 11, 15, 6);
      final List<String> approved = <String>[];
      final List<String> opened = <String>[];
      int waiting = 3;
      CopilotController scout({bool viewOnly = false}) => CopilotController(
        allowed: true,
        orders: _waitingOrders(countWaiting: () async => waiting),
        approvals: OrderApprovalActions(
          canDecide: (Map<String, dynamic> o) => o['status'] == 'submitted',
          limitWarnings: (Map<String, dynamic> o) async => o['orderId'] == 'O2'
              ? const <String>["Oat: 6 ordered; this product's limit is 5."]
              : const <String>[],
          approve: (Map<String, dynamic> o) async {
            approved.add('${o['orderId']}');
            waiting--;
            return null;
          },
        ),
        ordersViewOnly: viewOnly,
        loadItems: () async => (
          items: const <ActionCentreItem>[],
          failedSources: const <String>[],
        ),
        readStatus: (_) async => 'new',
        writeStatus: (_, _, _) async => false,
        openPage: (String key) async {
          opened.add(key);
          return true;
        },
        clock: () => now,
      );

      final CopilotController admin = scout();
      expect(await admin.handle('Show orders waiting for approval'), isTrue);
      expect(await admin.handle('yeah approve it'), isTrue);
      final CopilotEntry offer = admin.entries.last;
      expect(
        offer.text,
        '3 orders are waiting for approval (all dates, the same count as the home page). Approve 3 orders?',
      );
      final PendingAction? pending = offer.pending;
      expect(pending, isA<PendingOrderApproval>());
      expect(
        (pending! as PendingOrderApproval).lines.first,
        'O3 · Shop 3 · Unknown salesperson · RM 100.00 · 2 days old',
      );
      expect(approved, isEmpty);
      expect(opened, isEmpty);

      expect(await admin.handle('confirm'), isTrue);
      expect(approved, <String>['O3', 'O1']);
      final CopilotEntry result = admin.entries.last;
      expect(
        result.text,
        'Approved 2. 1 more waits.\nSkipped 1. Open it to decide there.',
      );
      expect(result.dataUsed, isNotNull);
      final Object? card = result.card;
      expect(card, isA<SkippedOrdersCard>());
      expect(
        (card! as SkippedOrdersCard).view.rows.single,
        "O2 · Shop 2 · Oat: 6 ordered; this product's limit is 5.",
      );
      expect(admin.pending, isNull);

      approved.clear();
      final CopilotController late = scout();
      await late.handle('yeah approve it');
      now = now.add(kCopilotConfirmWindow + const Duration(seconds: 1));
      await late.handle('confirm');
      expect(late.entries.last.text, 'That confirmation expired. Ask again.');
      expect(approved, isEmpty);

      final CopilotController manager = scout(viewOnly: true);
      await manager.handle('approve the pending orders');
      expect(
        manager.entries.last.text,
        contains('Order approval is view only for your role.'),
      );
      expect(manager.pending, isNull);
      await manager.handle('confirm');
      expect(approved, isEmpty);

      expect(
        intentFromCall('approve_orders', const <String, Object?>{}),
        isNull,
      );
    },
  );

  testWidgets(
    'the person\'s message and Scout\'s answer can be selected and copied, and a button still works',
    (WidgetTester tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            copied =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      int retried = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: DsoTheme.light,
          home: Scaffold(
            body: SelectionArea(
              child: ListView(
                children: <Widget>[
                  const CopilotUserBubble(text: 'who is mark zuckerberg'),
                  CopilotAssistantRow(
                    children: <Widget>[
                      const CopilotText('Scout answer line'),
                      CopilotRetryButton(onPressed: () => retried++),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final Finder mine = find.text('who is mark zuckerberg');
      final Color bubble = tester.element(mine).dso.accent;
      final Color? highlight = tester
          .renderObject<RenderParagraph>(
            find.descendant(of: mine, matching: find.byType(RichText)),
          )
          .selectionColor;
      expect(highlight, isNotNull);
      expect(
        (Color.alphaBlend(highlight!, bubble).computeLuminance() -
                bubble.computeLuminance())
            .abs(),
        greaterThan(0.1),
        reason: 'a selection on the green bubble must be visible',
      );

      final TestGesture drag = await tester.startGesture(
        tester.getTopLeft(mine) + const Offset(1, 4),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await drag.moveTo(
        tester.getBottomRight(find.text('Scout answer line')) -
            const Offset(1, 4),
      );
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(copied, contains('who is mark zuckerberg'));
      expect(copied, contains('Scout answer line'));

      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(retried, 1);
    },
  );
}
