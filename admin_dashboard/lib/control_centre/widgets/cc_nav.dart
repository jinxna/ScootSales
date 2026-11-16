import 'cc_shell.dart';

class CcNav {
  const CcNav({
    required this.go,
    required this.openCompany,
    required this.openInvoice,
    required this.openOnboarding,
  });

  final void Function(CcSection section) go;
  final void Function(String tenantId, {int tab}) openCompany;
  final void Function(String invoiceId) openInvoice;
  final void Function(String draftId) openOnboarding;
}

class CompanyTab {
  const CompanyTab._();

  static const int overview = 0;
  static const int invoices = 1;
  static const int payments = 2;
  static const int requests = 3;
  static const int emails = 4;
  static const int activity = 5;
  static const int technical = 6;
}
