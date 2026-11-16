import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../app/lifecycle_notice.dart';
import '../../app/workspace_runtime.dart';
import '../../models/user_profile.dart';
import '../../services/auth_service.dart';
import '../help/faq_page.dart';
import 'views/account_cms_page.dart';

class RestrictedWorkspacePage extends StatelessWidget {
  const RestrictedWorkspacePage({
    super.key,
    required this.currentUser,
    required this.lifecycleState,
    this.retentionEndsAt,
  });

  final UserProfile currentUser;
  final String? lifecycleState;
  final DateTime? retentionEndsAt;

  static String bannerText(
    WorkspaceConfig? workspace,
    String? lifecycleState, {
    DateTime? retentionEndsAt,
  }) => restrictedNotice(
    workspace?.legalName ?? 'This company',
    lifecycleState,
    retentionEndsAt,
  );

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Scaffold(
      backgroundColor: c.page,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ScootNotice(
                  tone: ScootTone.danger,
                  icon: ScootIcons.lock,
                  title: 'Workspace restricted',
                  message: bannerText(
                    WorkspaceRuntime.current,
                    lifecycleState,
                    retentionEndsAt: retentionEndsAt,
                  ),
                  liveRegion: true,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(
                      currentUser.email,
                      style: ScootType.small.copyWith(color: c.muted),
                    ),
                    TextButton(
                      onPressed: () => showFaq(
                        context,
                        currentUser,
                        initialId: 'status-suspended-roles',
                      ),
                      child: const Text('Questions about this status'),
                    ),
                    OutlinedButton(
                      onPressed: () => AuthService.instance.signOut(),
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(22, 16, 22, 18),
              child: AccountCmsPage(),
            ),
          ),
        ],
      ),
    );
  }
}
