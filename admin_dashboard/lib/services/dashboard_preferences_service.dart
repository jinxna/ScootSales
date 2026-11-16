import 'package:cloud_firestore/cloud_firestore.dart';

class DashboardPreferences {
  const DashboardPreferences({
    required this.selectedCards,
    required this.cardOrder,
    required this.defaultTimeframe,
  });

  final List<String> selectedCards;

  final List<String> cardOrder;

  final String defaultTimeframe;

  bool get isEmpty => selectedCards.isEmpty && cardOrder.isEmpty;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'selectedCards': selectedCards,
    'cardOrder': cardOrder,
    'defaultTimeframe': defaultTimeframe,
  };

  factory DashboardPreferences.fromMap(Map<String, dynamic> map) {
    List<String> stringList(Object? value) => value is List
        ? value.map((Object? e) => e.toString()).toList()
        : <String>[];
    return DashboardPreferences(
      selectedCards: stringList(map['selectedCards']),
      cardOrder: stringList(map['cardOrder']),
      defaultTimeframe: (map['defaultTimeframe'] ?? 'today').toString(),
    );
  }
}

class DashboardPreferencesService {
  DashboardPreferencesService();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<DashboardPreferences?> load(String uid) async {
    if (uid.trim().isEmpty) return null;
    try {
      final DocumentSnapshot<Map<String, dynamic>> doc = await _db
          .collection('dashboard_preferences')
          .doc(uid)
          .get();
      if (!doc.exists) return null;
      final Map<String, dynamic>? data = doc.data();
      if (data == null) return null;
      final DashboardPreferences prefs = DashboardPreferences.fromMap(data);
      return prefs.isEmpty ? null : prefs;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String uid, DashboardPreferences prefs) async {
    if (uid.trim().isEmpty) return;
    await _db.collection('dashboard_preferences').doc(uid).set(<String, dynamic>{
      ...prefs.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<Map<String, dynamic>> loadCatalogueView(
    String uid,
    String pageKey,
  ) async {
    if (uid.trim().isEmpty) return <String, dynamic>{};
    try {
      final DocumentSnapshot<Map<String, dynamic>> doc = await _db
          .collection('dashboard_preferences')
          .doc(uid)
          .get();
      final Object? views = doc.data()?['catalogueViews'];
      final Object? view = views is Map ? views[pageKey] : null;
      return view is Map
          ? Map<String, dynamic>.from(view)
          : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> saveCatalogueView(
    String uid,
    String pageKey,
    Map<String, dynamic> view,
  ) async {
    if (uid.trim().isEmpty) return;
    await _db.collection('dashboard_preferences').doc(uid).set(
      <String, dynamic>{
        'catalogueViews': <String, dynamic>{pageKey: view},
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Future<void> reset(String uid) async {
    if (uid.trim().isEmpty) return;
    try {
      await _db.collection('dashboard_preferences').doc(uid).delete();
    } catch (_) {
    }
  }
}
