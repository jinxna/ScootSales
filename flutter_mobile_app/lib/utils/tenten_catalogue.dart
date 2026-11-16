import 'demo_data.dart';
import 'catalogue_product_availability.dart';

bool isOrderableCatalogueProduct(Map<String, dynamic> product) {
  return !isDemoRecord(product) && isCatalogueProductVisible(product);
}
