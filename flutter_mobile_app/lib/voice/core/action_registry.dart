import 'voice_types.dart';

const Set<String> kVoiceQuantityUnits = <String>{
  'box',
  'set',
  'pc',
  'piece',
  'unit',
};

enum VoiceRisk { green, yellow, red, blocked }

class VoiceSurfaceIds {
  VoiceSurfaceIds._();

  static const String overview = 'overview';
  static const String assignedRoute = 'assigned_route';
  static const String guidedVisit = 'guided_visit';
  static const String orderHistory = 'order_history';
  static const String addToCart = 'add_to_cart';
  static const String orderCart = 'order_cart';
  static const String orderSignature = 'order_signature';
}

class VoiceActionDefinition {
  VoiceActionDefinition({
    required this.id,
    required this.schemaVersion,
    required this.risk,
    required Set<String> permittedRoles,
    required Set<String> permittedSurfaces,
    required Set<String> parameterNames,
    required this.enabled,
    required this.requiresConfirmation,
    required this.allowOffline,
    required this.requiresAuthenticatedUser,
    this.maxQuantity,
  }) : permittedRoles = Set<String>.unmodifiable(permittedRoles),
       permittedSurfaces = Set<String>.unmodifiable(permittedSurfaces),
       parameterNames = Set<String>.unmodifiable(parameterNames);

  final VoiceActionId id;
  final int schemaVersion;
  final VoiceRisk risk;
  final Set<String> permittedRoles;
  final Set<String> permittedSurfaces;
  final Set<String> parameterNames;
  final bool enabled;
  final bool requiresConfirmation;
  final bool allowOffline;
  final bool requiresAuthenticatedUser;
  final int? maxQuantity;

  bool allowsRole(String role) {
    final String normalized = role.trim().toLowerCase();
    return permittedRoles.contains(normalized);
  }

  bool allowsSurface(String surfaceId) {
    return permittedSurfaces.contains(surfaceId.trim().toLowerCase());
  }

  VoicePolicyFailure? validateParameters(Map<String, Object?> parameters) {
    if (!parameters.keys.every(parameterNames.contains) ||
        parameters.length != parameterNames.length) {
      return VoicePolicyFailure.invalidParameters;
    }

    switch (id) {
      case VoiceActionId.searchProducts:
        final Object? query = parameters['query'];
        if (query is! String || query.trim().isEmpty || query.length > 200) {
          return VoicePolicyFailure.invalidParameters;
        }
      case VoiceActionId.setDraftOrderQuantity:
        final Object? query = parameters['productQuery'];
        final Object? quantity = parameters['quantity'];
        final Object? unit = parameters['unit'];
        if (query is! String || query.trim().isEmpty || query.length > 200) {
          return VoicePolicyFailure.invalidParameters;
        }
        if (quantity is! int ||
            quantity < 1 ||
            (maxQuantity != null && quantity > maxQuantity!)) {
          return VoicePolicyFailure.invalidParameters;
        }
        if (!kVoiceQuantityUnits.contains(unit)) {
          return VoicePolicyFailure.invalidParameters;
        }
      default:
        break;
    }

    return null;
  }
}

class VoiceActionRegistry {
  VoiceActionRegistry(Iterable<VoiceActionDefinition> definitions)
    : _definitions = _build(definitions);

  final Map<VoiceActionId, VoiceActionDefinition> _definitions;

  static const Map<VoiceActionId, VoiceRisk> _protectedRisks =
      <VoiceActionId, VoiceRisk>{
        VoiceActionId.setDraftOrderQuantity: VoiceRisk.yellow,
        VoiceActionId.submitOrder: VoiceRisk.red,
        VoiceActionId.completeVisit: VoiceRisk.red,
        VoiceActionId.changeRouteState: VoiceRisk.red,
        VoiceActionId.recordOutcome: VoiceRisk.red,
        VoiceActionId.changeLocationState: VoiceRisk.blocked,
        VoiceActionId.changePermissions: VoiceRisk.blocked,
      };

  static Map<VoiceActionId, VoiceActionDefinition> _build(
    Iterable<VoiceActionDefinition> definitions,
  ) {
    final Map<VoiceActionId, VoiceActionDefinition> result =
        <VoiceActionId, VoiceActionDefinition>{};
    for (final VoiceActionDefinition definition in definitions) {
      if (result.containsKey(definition.id)) {
        throw StateError('Duplicate voice action definition: ${definition.id}');
      }
      final VoiceRisk? protectedRisk = _protectedRisks[definition.id];
      if (protectedRisk != null && definition.risk != protectedRisk) {
        throw StateError(
          'Protected voice action cannot be reclassified or enabled: '
          '${definition.id}',
        );
      }
      if ((protectedRisk == VoiceRisk.red ||
              protectedRisk == VoiceRisk.blocked) &&
          definition.enabled) {
        throw StateError(
          'Protected voice action cannot be reclassified or enabled: '
          '${definition.id}',
        );
      }
      if (definition.risk == VoiceRisk.yellow &&
          !definition.requiresConfirmation) {
        throw StateError(
          'Yellow voice actions must require physical confirmation: '
          '${definition.id}',
        );
      }
      if (definition.risk == VoiceRisk.blocked &&
          (definition.enabled || definition.requiresConfirmation)) {
        throw StateError(
          'Blocked voice actions cannot be enabled or confirmed: '
          '${definition.id}',
        );
      }
      if (definition.id == VoiceActionId.setDraftOrderQuantity &&
          (!definition.requiresConfirmation ||
              definition.maxQuantity == null ||
              definition.maxQuantity! < 1)) {
        throw StateError(
          'Quantity voice action requires Yellow confirmation and a '
          'positive maximum',
        );
      }
      result[definition.id] = definition;
    }
    return Map<VoiceActionId, VoiceActionDefinition>.unmodifiable(result);
  }

  VoiceActionDefinition? definitionFor(VoiceActionId action) {
    return _definitions[action];
  }

  VoiceActionDefinition? definitionForCode(String code) {
    for (final definition in _definitions.values) {
      if (definition.id.code == code) return definition;
    }
    return null;
  }

  static VoiceActionRegistry defaultRegistry({
    required int maxOrderQuantity,
    bool visitBriefsEnabled = true,
  }) {
    if (maxOrderQuantity < 1) {
      throw ArgumentError.value(
        maxOrderQuantity,
        'maxOrderQuantity',
        'must be positive',
      );
    }

    const Set<String> roles = <String>{
      'salesman',
      'sales representative',
      'sales_representative',
    };

    return VoiceActionRegistry(<VoiceActionDefinition>[
      VoiceActionDefinition(
        id: VoiceActionId.openAssignedRoute,
        schemaVersion: 1,
        risk: VoiceRisk.green,
        permittedRoles: roles,
        permittedSurfaces: <String>{
          VoiceSurfaceIds.overview,
          VoiceSurfaceIds.assignedRoute,
          VoiceSurfaceIds.guidedVisit,
        },
        parameterNames: const <String>{},
        enabled: true,
        requiresConfirmation: false,
        allowOffline: true,
        requiresAuthenticatedUser: true,
      ),
      VoiceActionDefinition(
        id: VoiceActionId.openCurrentVisit,
        schemaVersion: 1,
        risk: VoiceRisk.green,
        permittedRoles: roles,
        permittedSurfaces: <String>{
          VoiceSurfaceIds.assignedRoute,
          VoiceSurfaceIds.guidedVisit,
        },
        parameterNames: const <String>{},
        enabled: true,
        requiresConfirmation: false,
        allowOffline: true,
        requiresAuthenticatedUser: true,
      ),
      VoiceActionDefinition(
        id: VoiceActionId.openCart,
        schemaVersion: 1,
        risk: VoiceRisk.green,
        permittedRoles: roles,
        permittedSurfaces: <String>{
          VoiceSurfaceIds.assignedRoute,
          VoiceSurfaceIds.guidedVisit,
        },
        parameterNames: const <String>{},
        enabled: true,
        requiresConfirmation: false,
        allowOffline: true,
        requiresAuthenticatedUser: true,
      ),
      VoiceActionDefinition(
        id: VoiceActionId.openOrderHistory,
        schemaVersion: 1,
        risk: VoiceRisk.green,
        permittedRoles: roles,
        permittedSurfaces: <String>{
          VoiceSurfaceIds.overview,
          VoiceSurfaceIds.assignedRoute,
          VoiceSurfaceIds.guidedVisit,
          VoiceSurfaceIds.orderHistory,
        },
        parameterNames: const <String>{},
        enabled: true,
        requiresConfirmation: false,
        allowOffline: true,
        requiresAuthenticatedUser: true,
      ),
      VoiceActionDefinition(
        id: VoiceActionId.searchProducts,
        schemaVersion: 1,
        risk: VoiceRisk.green,
        permittedRoles: roles,
        permittedSurfaces: <String>{
          VoiceSurfaceIds.addToCart,
          VoiceSurfaceIds.orderCart,
        },
        parameterNames: const <String>{'query'},
        enabled: true,
        requiresConfirmation: false,
        allowOffline: true,
        requiresAuthenticatedUser: true,
      ),
      VoiceActionDefinition(
        id: VoiceActionId.clearProductSearch,
        schemaVersion: 1,
        risk: VoiceRisk.green,
        permittedRoles: roles,
        permittedSurfaces: <String>{
          VoiceSurfaceIds.addToCart,
          VoiceSurfaceIds.orderCart,
        },
        parameterNames: const <String>{},
        enabled: true,
        requiresConfirmation: false,
        allowOffline: true,
        requiresAuthenticatedUser: true,
      ),
      VoiceActionDefinition(
        id: VoiceActionId.showVisitBrief,
        schemaVersion: 1,
        risk: VoiceRisk.green,
        permittedRoles: roles,
        permittedSurfaces: <String>{
          VoiceSurfaceIds.assignedRoute,
          VoiceSurfaceIds.guidedVisit,
        },
        parameterNames: const <String>{},
        enabled: visitBriefsEnabled,
        requiresConfirmation: false,
        allowOffline: true,
        requiresAuthenticatedUser: true,
      ),
      VoiceActionDefinition(
        id: VoiceActionId.setDraftOrderQuantity,
        schemaVersion: 1,
        risk: VoiceRisk.yellow,
        permittedRoles: roles,
        permittedSurfaces: <String>{VoiceSurfaceIds.orderSignature},
        parameterNames: const <String>{'productQuery', 'quantity', 'unit'},
        enabled: true,
        requiresConfirmation: true,
        allowOffline: true,
        requiresAuthenticatedUser: true,
        maxQuantity: maxOrderQuantity,
      ),
      VoiceActionDefinition(
        id: VoiceActionId.submitOrder,
        schemaVersion: 1,
        risk: VoiceRisk.red,
        permittedRoles: roles,
        permittedSurfaces: <String>{
          VoiceSurfaceIds.guidedVisit,
          VoiceSurfaceIds.orderCart,
          VoiceSurfaceIds.orderSignature,
        },
        parameterNames: const <String>{},
        enabled: false,
        requiresConfirmation: true,
        allowOffline: false,
        requiresAuthenticatedUser: true,
      ),
      VoiceActionDefinition(
        id: VoiceActionId.completeVisit,
        schemaVersion: 1,
        risk: VoiceRisk.red,
        permittedRoles: roles,
        permittedSurfaces: <String>{VoiceSurfaceIds.guidedVisit},
        parameterNames: const <String>{},
        enabled: false,
        requiresConfirmation: true,
        allowOffline: false,
        requiresAuthenticatedUser: true,
      ),
      VoiceActionDefinition(
        id: VoiceActionId.changeRouteState,
        schemaVersion: 1,
        risk: VoiceRisk.red,
        permittedRoles: roles,
        permittedSurfaces: <String>{VoiceSurfaceIds.assignedRoute},
        parameterNames: const <String>{},
        enabled: false,
        requiresConfirmation: true,
        allowOffline: false,
        requiresAuthenticatedUser: true,
      ),
      VoiceActionDefinition(
        id: VoiceActionId.recordOutcome,
        schemaVersion: 1,
        risk: VoiceRisk.red,
        permittedRoles: roles,
        permittedSurfaces: <String>{VoiceSurfaceIds.guidedVisit},
        parameterNames: const <String>{},
        enabled: false,
        requiresConfirmation: true,
        allowOffline: false,
        requiresAuthenticatedUser: true,
      ),
      VoiceActionDefinition(
        id: VoiceActionId.changeLocationState,
        schemaVersion: 1,
        risk: VoiceRisk.blocked,
        permittedRoles: roles,
        permittedSurfaces: <String>{VoiceSurfaceIds.guidedVisit},
        parameterNames: const <String>{},
        enabled: false,
        requiresConfirmation: false,
        allowOffline: false,
        requiresAuthenticatedUser: true,
      ),
      VoiceActionDefinition(
        id: VoiceActionId.changePermissions,
        schemaVersion: 1,
        risk: VoiceRisk.blocked,
        permittedRoles: roles,
        permittedSurfaces: const <String>{},
        parameterNames: const <String>{},
        enabled: false,
        requiresConfirmation: false,
        allowOffline: false,
        requiresAuthenticatedUser: true,
      ),
    ]);
  }
}
