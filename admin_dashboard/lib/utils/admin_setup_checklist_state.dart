import '../app/build_flags.dart';

class AdminSetupChecklistCounts {
  const AdminSetupChecklistCounts({
    required this.branches,
    required this.activeSupervisors,
    required this.activeSalespeopleWithBranch,
    required this.supervisorsWithAssignedSalespeople,
    required this.nonRetiredRetailers,
    required this.retailersAssignedToValidSalespeople,
    required this.visibleCategorizedProducts,
    required this.scoreSheetSettings,
    required this.publishedRoutes,
    required this.aiRuns,
  });

  final int? branches;
  final int? activeSupervisors;
  final int? activeSalespeopleWithBranch;
  final int? supervisorsWithAssignedSalespeople;
  final int? nonRetiredRetailers;
  final int? retailersAssignedToValidSalespeople;
  final int? visibleCategorizedProducts;
  final int? scoreSheetSettings;
  final int? publishedRoutes;
  final int? aiRuns;
}

enum SetupChecklistStepId {
  createBranch,
  addSupervisor,
  addSalespeople,
  assignSalespeople,
  addRetailers,
  assignRetailers,
  addProducts,
  scoreSheet,
  publishRoute,
  prepareAi,
}

enum SetupChecklistStepStatus { complete, incomplete, couldNotCheck }

class AdminSetupChecklistStepState {
  const AdminSetupChecklistStepState({
    required this.id,
    required this.title,
    required this.explanation,
    required this.navigationKey,
    required this.status,
    this.isRequired = true,
  });

  final SetupChecklistStepId id;
  final String title;
  final String explanation;
  final String navigationKey;
  final SetupChecklistStepStatus status;
  final bool isRequired;
}

List<AdminSetupChecklistStepState> adminSetupChecklistSteps(
  AdminSetupChecklistCounts counts,
) {
  AdminSetupChecklistStepState step({
    required SetupChecklistStepId id,
    required String title,
    required String explanation,
    required String navigationKey,
    required int? count,
    bool isRequired = true,
  }) => AdminSetupChecklistStepState(
    id: id,
    title: title,
    explanation: explanation,
    navigationKey: navigationKey,
    status: count == null
        ? SetupChecklistStepStatus.couldNotCheck
        : count > 0
        ? SetupChecklistStepStatus.complete
        : SetupChecklistStepStatus.incomplete,
    isRequired: isRequired,
  );

  return <AdminSetupChecklistStepState>[
    step(
      id: SetupChecklistStepId.createBranch,
      title: 'Create a branch',
      explanation: 'Add at least one branch for your team.',
      navigationKey: 'branches',
      count: counts.branches,
    ),
    step(
      id: SetupChecklistStepId.addSupervisor,
      title: 'Add a supervisor',
      explanation: 'Create at least one active supervisor account.',
      navigationKey: 'users',
      count: counts.activeSupervisors,
    ),
    step(
      id: SetupChecklistStepId.addSalespeople,
      title: 'Add salespeople',
      explanation: 'Create an active salesperson and assign a branch.',
      navigationKey: 'users',
      count: counts.activeSalespeopleWithBranch,
    ),
    step(
      id: SetupChecklistStepId.assignSalespeople,
      title: 'Assign salespeople to a supervisor',
      explanation: 'Give a supervisor at least one valid salesperson.',
      navigationKey: 'users',
      count: counts.supervisorsWithAssignedSalespeople,
    ),
    step(
      id: SetupChecklistStepId.addRetailers,
      title: 'Add retailers',
      explanation: 'Add at least one retailer that is not retired.',
      navigationKey: 'retailer',
      count: counts.nonRetiredRetailers,
    ),
    step(
      id: SetupChecklistStepId.assignRetailers,
      title: 'Assign retailers to salespeople',
      explanation: 'Assign a retailer to an active salesperson.',
      navigationKey: 'retailer',
      count: counts.retailersAssignedToValidSalespeople,
    ),
    step(
      id: SetupChecklistStepId.addProducts,
      title: 'Add products',
      explanation: 'Make a product visible with a department and category.',
      navigationKey: 'product',
      count: counts.visibleCategorizedProducts,
    ),
    step(
      id: SetupChecklistStepId.scoreSheet,
      title: 'Configure a retailer score sheet (optional)',
      explanation:
          'Use this for per-retailer product visibility, order and price overrides.',
      navigationKey: 'retailer_scoresheets',
      count: counts.scoreSheetSettings,
      isRequired: false,
    ),
    step(
      id: SetupChecklistStepId.publishRoute,
      title: 'Publish a first route',
      explanation: 'Publish at least one route plan for a salesperson.',
      navigationKey: 'route_planner',
      count: counts.publishedRoutes,
    ),
    if (!isBasicEdition)
      step(
        id: SetupChecklistStepId.prepareAi,
        title: 'Prepare AI data (optional)',
        explanation: 'AI panels read saved Firestore data prepared offline.',
        navigationKey: 'prediction',
        count: counts.aiRuns,
        isRequired: false,
      ),
  ];
}

bool adminSetupChecklistRequiredStepsComplete(
  AdminSetupChecklistCounts counts,
) => adminSetupChecklistSteps(counts)
    .where((AdminSetupChecklistStepState step) => step.isRequired)
    .every(
      (AdminSetupChecklistStepState step) =>
          step.status == SetupChecklistStepStatus.complete,
    );
