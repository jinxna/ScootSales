import 'package:latlong2/latlong.dart';

import '../../utils/geo_field_utils.dart';
import '../../utils/order_data_utils.dart';
import '../../utils/retailer_readiness.dart';

class RetailerMapPoint {
  const RetailerMapPoint({
    required this.id,
    required this.name,
    required this.code,
    required this.point,
    required this.status,
    this.branch = '',
    this.region = '',
    this.salesman = '',
    this.address = '',
  });

  factory RetailerMapPoint.fromRow(Map<String, dynamic> row) {
    final String id = dataText(
      row['docId'] ?? row['retailerId'] ?? row['id'],
    ).trim();
    return RetailerMapPoint(
      id: id,
      name: dataText(
        row['retailerName'] ?? row['name'] ?? row['outletName'] ?? id,
      ).trim(),
      code: dataText(row['retailerCode'] ?? row['code']).trim(),
      point: readLatLng(row),
      status: retailerCoordinateStatus(row),
      branch: dataText(row['branchName'] ?? row['branchId']).trim(),
      region: retailerRegion(row),
      salesman: dataText(
        row['assignedSalesmanName'] ?? row['salesmanName'],
      ).trim(),
      address: dataText(
        row['address'] ?? row['area'] ?? row['locationName'],
      ).trim(),
    );
  }

  final String id;
  final String name;
  final String code;
  final LatLng? point;
  final CoordinateStatus status;
  final String branch;
  final String region;
  final String salesman;
  final String address;

  bool get isPlottable =>
      point != null &&
      status != CoordinateStatus.missing &&
      status != CoordinateStatus.invalid;

  bool get isVerified => status == CoordinateStatus.verified;
}
