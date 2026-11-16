import 'company_project.dart';



class CompanyRuntime {
  CompanyRuntime._();

  static ActiveCompany? _current;
  static ActiveCompany? get current => _current;

  static bool sameIdentity(ActiveCompany left, ActiveCompany right) =>
      left.options == right.options &&
      left.tenantId == right.tenantId &&
      left.workspace == right.workspace &&
      left.authTenantId == right.authTenantId;

  static void bindInitialized(ActiveCompany company) {
    final ActiveCompany? initialized = _current;
    if (initialized != null && !sameIdentity(initialized, company)) {
      throw StateError('The initialized company cannot change in this process.');
    }
    _current = company;
  }
}
