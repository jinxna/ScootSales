import 'workspace_runtime.dart';

const bool kUserTestingMode = bool.fromEnvironment('USER_TESTING');

bool get isBasicEdition => WorkspaceRuntime.current?.isBasicEdition ?? false;

const Set<String> _scenarioStudioGuardAliases = <String>{
  'scenario_workbench',
  'route_scenario_planning',
  'route_scenarios',
};

const Set<String> kUserTestingHiddenPageKeys = <String>{
  'system_health',
  'trust_impact',
};

const Set<String> kAdvancedOnlyPageKeys = <String>{
  'prediction',
  'team_forecast',
  'team_action_center',
  'team_ai_summary',
  'trust_impact',
  'management_action_center',
  'weekly_ai_summary',
};

const Set<String> kBetaPageKeys = <String>{
  'import_preview',
  'prediction',
  'team_forecast',
  'team_action_center',
  'team_ai_summary',
};

bool isPageHiddenInUserTesting(String key) =>
    (kUserTestingMode &&
        (kUserTestingHiddenPageKeys.contains(key) ||
            _scenarioStudioGuardAliases.contains(key))) ||
    (isBasicEdition &&
        (kAdvancedOnlyPageKeys.contains(key) ||
            _scenarioStudioGuardAliases.contains(key)));

bool isBetaPageKey(String key) => kBetaPageKeys.contains(key);

List<T> visiblePagesForBuild<T>(
  Iterable<T> pages,
  String Function(T page) pageKey,
) => pages
    .where((T page) => !isPageHiddenInUserTesting(pageKey(page)))
    .toList(growable: false);
