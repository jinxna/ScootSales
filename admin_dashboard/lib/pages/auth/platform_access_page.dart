import 'package:flutter/material.dart';

import '../../models/user_profile.dart';
import '../../services/auth_service.dart';
import 'package:scoot_design/scoot_design.dart';
import '../help/faq_page.dart';

class PlatformAccessPage extends StatelessWidget {
  const PlatformAccessPage({
    super.key,
    required this.title,
    required this.message,
    required this.profile,
  });

  final String title;
  final String message;
  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Scaffold(
      backgroundColor: c.page,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ScootCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: ScootType.h1.copyWith(color: c.ink),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ScootNotice(
                    tone: ScootTone.warning,
                    icon: ScootIcons.lock,
                    message: message,
                    liveRegion: true,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Signed in as ${profile.name} (${profile.employeeCode}), ${profile.roleLabel}.',
                    style: ScootType.small.copyWith(color: c.muted),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: <Widget>[
                      FilledButton(
                        onPressed: () async => AuthService.instance.signOut(),
                        child: const Text('Back to sign in'),
                      ),
                      TextButton(
                        onPressed: () => showFaq(
                          context,
                          profile,
                          initialId: 'status-suspended-roles',
                        ),
                        child: const Text('Questions about this status'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
