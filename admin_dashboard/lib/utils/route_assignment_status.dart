enum RouteAssignmentStage { draft, approved, published, unknown }

class RouteAssignmentStatus {
  const RouteAssignmentStatus({
    required this.stage,
    required this.title,
    required this.message,
  });

  final RouteAssignmentStage stage;
  final String title;
  final String message;
}

RouteAssignmentStatus routeAssignmentStatus({
  required String status,
  required String salesmanName,
}) {
  final String safeName = salesmanName.trim().isEmpty
      ? 'the salesperson'
      : salesmanName.trim();
  switch (status.trim().toLowerCase()) {
    case 'draft':
      return RouteAssignmentStatus(
        stage: RouteAssignmentStage.draft,
        title: 'Not assigned yet',
        message:
            'This is a draft. Save any changes, approve it, then publish it '
            'to send the route to $safeName\'s mobile app.',
      );
    case 'approved':
      return RouteAssignmentStatus(
        stage: RouteAssignmentStage.approved,
        title: 'Approved, but not assigned yet',
        message:
            'Select Publish to assign this route to $safeName. The mobile app '
            'will receive the published plan through its live sync.',
      );
    case 'published':
      return RouteAssignmentStatus(
        stage: RouteAssignmentStage.published,
        title: 'Published and assigned',
        message:
            'This route is assigned to $safeName. Their mobile app updates '
            'automatically while online and keeps the last synced route '
            'available offline.',
      );
    default:
      return RouteAssignmentStatus(
        stage: RouteAssignmentStage.unknown,
        title: 'Assignment status unavailable',
        message:
            'This route has an unsupported status and has not been confirmed '
            'as assigned to $safeName.',
      );
  }
}
