import 'retailer_form_utils.dart';

enum RetailerImportKind { retailers, assignments }

class RetailerImportRow {
  const RetailerImportRow({
    required this.fields,
    required this.id,
    required this.errors,
    required this.warnings,
    required this.ignoredColumns,
  });

  final Map<String, dynamic> fields;

  final String id;
  final List<String> errors;
  final List<String> warnings;

  final List<String> ignoredColumns;
}

String normaliseImportHeader(String header) =>
    header.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

const Map<String, String> _headerAliases = <String, String>{
  'retailerid': 'retailerId',
  'retailercode': 'retailerId',
  'customercode': 'retailerId',
  'customerid': 'retailerId',
  'id': 'retailerId',
  'retailername': 'retailerName',
  'name': 'retailerName',
  'outletname': 'retailerName',
  'customername': 'retailerName',
  'martname': 'retailerName',
  'area': 'area',
  'address': 'address',
  'contactperson': 'contactPerson',
  'contactname': 'contactPerson',
  'contact': 'contactPerson',
  'assignedsalesmanid': 'assignedSalesmanId',
  'salesmancode': 'assignedSalesmanId',
  'salesmanid': 'assignedSalesmanId',
  'staffid': 'assignedSalesmanId',
  'branchid': 'branchId',
  'branchcode': 'branchId',
  'status': 'status',
};

const Set<String> _coordinateHeaders = <String>{
  'latitude',
  'longitude',
  'lat',
  'lng',
  'lon',
  'long',
  'gpslatitude',
  'gpslongitude',
};

RetailerImportRow mapRetailerImportRow(
  Map<String, dynamic> raw, {
  required RetailerImportKind kind,
}) {
  final Map<String, dynamic> canonical = <String, dynamic>{};
  final List<String> ignored = <String>[];
  bool coordinatesSeen = false;

  for (final MapEntry<String, dynamic> entry in raw.entries) {
    if (entry.key.startsWith('_')) continue;
    final String normalised = normaliseImportHeader(entry.key);
    final String? field = _headerAliases[normalised];
    final String value = _clean(entry.value);
    if (field == null) {
      if (_coordinateHeaders.contains(normalised)) {
        coordinatesSeen = true;
      } else if (value.isNotEmpty) {
        ignored.add(entry.key);
      }
      continue;
    }
    if (value.isEmpty) continue;
    canonical.putIfAbsent(field, () => value);
  }

  final List<String> errors = <String>[];
  final List<String> warnings = <String>[];
  if (ignored.isNotEmpty) {
    warnings.add('Unknown column(s) skipped: ${ignored.join(', ')}.');
  }
  if (coordinatesSeen) {
    warnings.add(
      'Coordinate columns are not imported. Set coordinates from the retailer '
      'form or Coordinate Review so they are verified.',
    );
  }

  String id = _clean(canonical['retailerId']);
  final String name = _clean(canonical['retailerName']);
  if (id.isNotEmpty && !isValidRetailerImportId(id)) {
    errors.add(
      'Retailer ID "$id" is not allowed. Remove "/" characters and keep it '
      'under 200 characters.',
    );
    id = '';
  }

  final Map<String, dynamic> fields = <String, dynamic>{};
  if (kind == RetailerImportKind.assignments) {
    if (id.isEmpty && errors.isEmpty) {
      errors.add('Missing retailer ID. Assignments cannot be matched by name.');
    }
    final String salesman = _clean(canonical['assignedSalesmanId']);
    final String branch = _clean(canonical['branchId']);
    if (salesman.isEmpty && branch.isEmpty) {
      errors.add('Nothing to assign: add a salesman code or a branch ID.');
    }
    if (salesman.isNotEmpty) fields['assignedSalesmanId'] = salesman;
    if (branch.isNotEmpty) fields['branchId'] = branch;
  } else {
    if (name.isEmpty) errors.add('Missing retailer name.');
    fields['retailerName'] = name;
    for (final String key in <String>['area', 'address', 'contactPerson']) {
      final String value = _clean(canonical[key]);
      if (value.isNotEmpty) fields[key] = value;
    }
    final String salesman = _clean(canonical['assignedSalesmanId']);
    if (salesman.isNotEmpty) fields['assignedSalesmanId'] = salesman;
    final String branch = _clean(canonical['branchId']);
    if (branch.isNotEmpty) fields['branchId'] = branch;
    final String status = _clean(canonical['status']);
    if (status.isNotEmpty) {
      final bool hidden = normaliseRetailerDisplayStatus(status) == 'Hide';
      fields['status'] = hidden ? 'hidden' : 'active';
      fields['stockListVisible'] = !hidden;
    }
    if (id.isEmpty && name.isNotEmpty && errors.isEmpty) {
      warnings.add('No retailer ID column; the ID is derived from the name.');
    }
  }

  return RetailerImportRow(
    fields: fields,
    id: id,
    errors: errors,
    warnings: warnings,
    ignoredColumns: ignored,
  );
}

bool isValidRetailerImportId(String id) {
  final String value = id.trim();
  if (value.isEmpty || value.length > 200) return false;
  if (value == '.' || value == '..') return false;
  if (value.contains('/')) return false;
  if (value.startsWith('__') && value.endsWith('__')) return false;
  return true;
}

String _clean(Object? value) {
  if (value == null) return '';
  final String text = value.toString().trim();
  return text.toLowerCase() == 'null' ? '' : text;
}
