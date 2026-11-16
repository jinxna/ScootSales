import '../edition.dart';
import '../utils/quantity_unit.dart';
import 'core/action_registry.dart';

VoiceActionRegistry buildVoiceActionRegistry() {
  return VoiceActionRegistry.defaultRegistry(
    maxOrderQuantity: absoluteMaxQtyPerLine,
    visitBriefsEnabled: !kBasicEdition,
  );
}
