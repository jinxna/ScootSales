class CompanyLifecycle {
  const CompanyLifecycle({
    required this.state,
    required this.access,
    this.cutAt,
    this.drainUntil,
    this.reactivatedAt,
  });

  final String state;
  final String access;
  final DateTime? cutAt;
  final DateTime? drainUntil;
  final DateTime? reactivatedAt;

  bool get isOpen => access == 'open';

  static CompanyLifecycle? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? access = raw['access'];
    if (access is! String || access.isEmpty) return null;
    DateTime? time(String key) {
      final Object? value = raw[key];
      return value is String ? DateTime.tryParse(value)?.toUtc() : null;
    }

    return CompanyLifecycle(
      state: (raw['state'] ?? '').toString(),
      access: access,
      cutAt: time('cutAt'),
      drainUntil: time('drainUntil'),
      reactivatedAt: time('reactivatedAt'),
    );
  }
}
