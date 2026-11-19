library;

import '../../utils/fuzzy_text.dart';

enum EntityKind { salesperson, retailer }

class EntityRef {
  const EntityRef({
    required this.kind,
    required this.id,
    required this.name,
    this.code = '',
    this.orderKeys = const <String>{},
  });

  final EntityKind kind;
  final String id;
  final String name;

  final String code;

  final Set<String> orderKeys;

  String get kindLabel =>
      kind == EntityKind.salesperson ? 'salesperson' : 'retailer';
}

sealed class Resolution {
  const Resolution();
}

class One extends Resolution {
  const One(this.entity);
  final EntityRef entity;
}

class Many extends Resolution {
  const Many(this.entities);
  final List<EntityRef> entities;
}

class None extends Resolution {
  const None();
}

const Map<String, String> _tokenVariants = <String, String>{
  'muhammad': 'muhammad',
  'mohammad': 'muhammad',
  'mohamad': 'muhammad',
  'mohamed': 'muhammad',
  'mohd': 'muhammad',
  'muhd': 'muhammad',
  'md': 'muhammad',
  'abd': 'abdul',
  'noor': 'nur',
  'nor': 'nur',
  'kdi': 'kedai',
  'kd': 'kedai',
  'psr': 'pasaraya',
  'psrya': 'pasaraya',
  'smkt': 'supermarket',
};

const Set<String> _dropTokens = <String>{
  'encik',
  'en',
  'cik',
  'puan',
  'pn',
  'tuan',
  'mr',
  'mrs',
  'ms',
  'bin',
  'binti',
  'bt',
  'bte',
  'al',
  'ap',
  'sdn',
  'bhd',
  'ent',
  'enterprise',
  'trading',
  'tdg',
  'store',
  'stores',
  'shop',
  'the',
};

String normaliseEntityName(String text) {
  String t = text.toLowerCase().replaceAll(RegExp(r"['’]s\b"), '');
  t = t.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  t = t
      .replaceAll(RegExp(r'\b(?:mini market|mini mart)\b'), 'minimarket')
      .replaceAll(RegExp(r'\bs market\b'), 'supermarket')
      .replaceAll(RegExp(r'\ba l\b'), ' ')
      .replaceAll(RegExp(r'\ba p\b'), ' ');
  t = t.replaceAllMapped(
    RegExp(r'\b([a-z])\s+(\d(?:\s+\d)+)\b'),
    (Match m) => '${m[1]}${m[2]!.replaceAll(' ', '')}',
  );
  final List<String> tokens = <String>[];
  for (final String raw in t.split(' ')) {
    if (raw.isEmpty || _dropTokens.contains(raw)) continue;
    tokens.add(_tokenVariants[raw] ?? raw);
  }
  return tokens.join(' ');
}

bool _prefix(String s, String c) =>
    s == c || (s.length >= 3 && c.startsWith(s));

int _tier(List<String> spoken, String spokenJoined, EntityRef e) {
  final String name = normaliseEntityName(e.name);
  final String code = normaliseEntityName(e.code);
  if (spokenJoined == name || (code.isNotEmpty && spokenJoined == code)) {
    return 10;
  }
  final List<String> cand = name.isEmpty ? <String>[] : name.split(' ');
  if (cand.isEmpty) return 0;
  if (spoken.every(cand.contains)) return 9;
  if (spoken.every((String s) => cand.any((String c) => _prefix(s, c)))) {
    return 8;
  }
  if (spoken.every((String s) => cand.any((String c) => isNearWord(s, c)))) {
    return 7;
  }
  return 0;
}

Resolution resolveEntity(String spoken, Iterable<EntityRef> pool) {
  final String joined = normaliseEntityName(spoken);
  if (joined.isEmpty) return const None();
  final List<String> tokens = joined.split(' ');
  int best = 0;
  final List<(int, EntityRef)> scored = <(int, EntityRef)>[];
  for (final EntityRef e in pool) {
    final int tier = _tier(tokens, joined, e);
    if (tier == 0) continue;
    scored.add((tier, e));
    if (tier > best) best = tier;
  }
  if (best == 0) return const None();
  final List<EntityRef> top =
      scored
          .where(((int, EntityRef) s) => s.$1 == best)
          .map(((int, EntityRef) s) => s.$2)
          .toList()
        ..sort((EntityRef a, EntityRef b) {
          final int byName = a.name.toLowerCase().compareTo(
            b.name.toLowerCase(),
          );
          return byName != 0 ? byName : a.id.compareTo(b.id);
        });
  if (top.length == 1) return One(top.first);
  return Many(top.take(5).toList(growable: false));
}

String _lower(Object? v) {
  final String t = v?.toString().trim().toLowerCase() ?? '';
  return t == 'null' ? '' : t;
}

const List<String> _salesmanOrderFields = <String>[
  'salesmanUid',
  'salesman_uid',
  'salesmanId',
  'salesman_id',
  'salesmanCode',
  'salesman_code',
  'staffId',
  'staff_id',
  'submittedByUid',
  'createdByUid',
  'uid',
  'userUid',
];

String _orderRetailerName(Map<String, dynamic> o) =>
    (o['retailerName'] ?? o['retailer_name'] ?? '').toString();

String _orderSalesmanName(Map<String, dynamic> o) =>
    (o['salesmanName'] ?? o['salesman_name'] ?? '').toString();

Set<String> _salesmanKeys(Map<String, dynamic> o) => <String>{
  for (final String f in _salesmanOrderFields)
    if (_lower(o[f]).isNotEmpty) _lower(o[f]),
};

bool orderMatchesEntity(EntityRef entity, Map<String, dynamic> order) {
  if (entity.kind == EntityKind.salesperson) {
    if (_salesmanKeys(order).any(entity.orderKeys.contains)) return true;
    return entity.orderKeys.contains(
      'n:${normaliseEntityName(_orderSalesmanName(order))}',
    );
  }
  final String id = _lower(order['retailerId'] ?? order['retailer_id']);
  if (id.isNotEmpty) return entity.orderKeys.contains(id);
  final String name = normaliseEntityName(_orderRetailerName(order));
  return name.isNotEmpty && entity.orderKeys.contains('n:$name');
}

List<EntityRef> entityPoolFromOrders(
  Iterable<Map<String, dynamic>> orders,
  Iterable<EntityRef> salespeople,
) {
  final Map<String, EntityRef> retailers = <String, EntityRef>{};
  final Map<String, EntityRef> orphans = <String, EntityRef>{};
  for (final Map<String, dynamic> o in orders) {
    final String rName = _orderRetailerName(o).trim();
    if (rName.isNotEmpty) {
      final String rId = _lower(o['retailerId'] ?? o['retailer_id']);
      final String nName = normaliseEntityName(rName);
      final String key = rId.isNotEmpty ? rId : 'n:$nName';
      retailers.putIfAbsent(
        key,
        () => EntityRef(
          kind: EntityKind.retailer,
          id: rId.isNotEmpty ? rId : key,
          name: rName,
          orderKeys: <String>{if (rId.isNotEmpty) rId else 'n:$nName'},
        ),
      );
    }
    final String sName = _orderSalesmanName(o).trim();
    if (sName.isEmpty) continue;
    if (salespeople.any((EntityRef p) => orderMatchesEntity(p, o))) continue;
    final Set<String> keys = _salesmanKeys(o);
    final String nName = normaliseEntityName(sName);
    final String key = keys.isNotEmpty ? keys.first : 'n:$nName';
    orphans.putIfAbsent(
      key,
      () => EntityRef(
        kind: EntityKind.salesperson,
        id: key,
        name: sName,
        orderKeys: <String>{...keys, 'n:$nName'},
      ),
    );
  }
  return <EntityRef>[...retailers.values, ...orphans.values];
}
