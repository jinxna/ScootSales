import '../pages/admin/navigation/cms_navigation.dart';
import 'dashboard_voice_types.dart';

List<DashboardVoicePage> dashboardVoicePagesFromCms(
  Iterable<CmsNavItem> items,
) {
  return items
      .map(
        (CmsNavItem item) => DashboardVoicePage(
          key: item.key,
          label: item.label,
          description: item.description,
          aliases: <String>{
            item.label,
            item.title,
            item.key.replaceAll('_', ' '),
            ...item.keywords,
            ...?_extraAliases[item.key],
          },
        ),
      )
      .toList(growable: false);
}

DashboardVoicePage dashboardVoicePage({
  required String key,
  required String label,
  String description = '',
  Iterable<String> aliases = const <String>[],
}) {
  return DashboardVoicePage(
    key: key,
    label: label,
    description: description,
    aliases: <String>{label, key.replaceAll('_', ' '), ...aliases},
  );
}

const Map<String, Set<String>> _extraAliases = <String, Set<String>>{
  'dashboard': <String>{'home', 'overview', 'main dashboard', 'go home'},
  'notifications': <String>{'alerts', 'notification feed'},
  'all_orders': <String>{'orders', 'submitted orders', 'order approval'},
  'purchase_order': <String>{'procurement', 'po', 'purchase orders'},
  'route_planner': <String>{'routes', 'weekly routes', 'route planning'},
  'prediction': <String>{
    'forecast',
    'demand forecast',
    'predictions',
    'how are the predictions doing',
  },
  'reports': <String>{'analytics', 'monthly analytics'},
  'trust_impact': <String>{'trust impact', 'evidence', 'abstentions'},
  'product': <String>{'products', 'product catalogue', 'catalogue'},
  'retailer': <String>{'retailers', 'outlets'},
  'user_directory': <String>{'users', 'staff directory'},
  'branches': <String>{'branch management'},
  'salesman_activity': <String>{
    'sales activity',
    'salesman tracking',
    'map',
    'how to see how my salesman are doing today',
  },
  'visit_logs': <String>{'visits', 'visit history'},
  'special_requests': <String>{'exceptions', 'request approvals'},
  'my_team': <String>{
    'my team',
    'my salesmen',
    'my salespeople',
    'team members',
    'branch team',
  },
  'team_orders': <String>{'team orders'},
  'team_visits': <String>{'team visits'},
  'team_activity': <String>{
    'team activity',
    'team map',
    'how to see how my salesman are doing today',
  },
  'team_forecast': <String>{'team forecast', 'how are the predictions doing'},
  'team_action_center': <String>{'action center', 'team actions'},
  'team_ai_summary': <String>{'weekly ai summary', 'team summary'},
};
