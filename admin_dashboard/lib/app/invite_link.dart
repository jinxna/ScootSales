import '../pages/auth/redeem_invitation_form.dart' show normalizeInvitationCode;

class InviteLink {
  const InviteLink._({this.workspace, this.code, this.problem});

  static const String pathSegment = 'invite';
  static const String _fragmentPrefix = 'invite=';
  static const String invalidMessage =
      'This invitation link is not valid. Enter the code from your '
      'invitation email below.';
  static const String otherWorkspaceMessage =
      'This invitation is for a different company. Open the link from your '
      'invitation email again.';

  static InviteLink? pending;

  final String? workspace;
  final String? code;
  final String? problem;

  static InviteLink? fromUri(Uri url) {
    final String fragment = url.fragment;
    final bool onInvitePath =
        url.pathSegments.where((String s) => s.isNotEmpty).lastOrNull ==
        pathSegment;
    if (!fragment.startsWith(_fragmentPrefix)) {
      return onInvitePath ? const InviteLink._(problem: invalidMessage) : null;
    }
    final List<String> parts = _decoded(
      fragment.substring(_fragmentPrefix.length),
    ).trim().split(':');
    final String code = parts.length == 4
        ? normalizeInvitationCode(parts[3])
        : '';
    if (parts.length != 4 ||
        parts[0] != 'scoot-invite' ||
        parts[1] != '1' ||
        parts[2].trim().isEmpty ||
        code.length != 12) {
      return const InviteLink._(problem: invalidMessage);
    }
    return InviteLink._(workspace: parts[2].trim(), code: code);
  }

  String? noticeFor(String? currentWorkspace) {
    if (problem != null) return problem;
    if (workspace != currentWorkspace) return otherWorkspaceMessage;
    return null;
  }

  static String _decoded(String value) {
    try {
      return Uri.decodeComponent(value);
    } on ArgumentError {
      return value;
    }
  }
}
