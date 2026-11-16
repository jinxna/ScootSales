import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../widgets/phone_card.dart';
import 'legal_document_screen.dart';

class AppSplashScreen extends StatefulWidget {
  const AppSplashScreen({
    super.key,
    required this.message,
    this.onRetry,
    this.stillLoadingAfter = ScootTiming.stillLoadingAfter,
  });

  final String message;
  final VoidCallback? onRetry;
  final Duration stillLoadingAfter;

  @override
  State<AppSplashScreen> createState() => _AppSplashScreenState();
}

class _AppSplashScreenState extends State<AppSplashScreen> {
  Timer? _timer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer(widget.stillLoadingAfter, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Scaffold(
      backgroundColor: c.page,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(ScootSpace.phoneGutter * 1.5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      widget.message,
                      textAlign: TextAlign.center,
                      style: ScootType.bodyStrong.copyWith(color: c.text2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const PhoneCard(
                    child: ScootSkeletonLines(
                      widthFactors: <double>[0.6, 0.9, 0.5],
                    ),
                  ),
                  if (_slow) ...<Widget>[
                    const SizedBox(height: 16),
                    widget.onRetry == null
                        ? const ScootNotice(
                            tone: ScootTone.neutral,
                            icon: ScootIcons.hourglass,
                            message:
                                'Still loading. The connection may be slow.',
                          )
                        : ScootStillLoadingBar(
                            message:
                                'Still loading. The connection may be slow.',
                            onRetry: () {
                              setState(() => _slow = false);
                              _start();
                              widget.onRetry!();
                            },
                          ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AccountAccessScreen extends StatelessWidget {
  const AccountAccessScreen({
    super.key,
    required this.title,
    required this.message,
    required this.onSignOut,
    this.primaryLabel,
    this.primaryAction,
  });

  final String title;
  final String message;
  final String? primaryLabel;
  final VoidCallback? primaryAction;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Scaffold(
      backgroundColor: c.page,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Padding(
                padding: const EdgeInsets.all(ScootSpace.phoneGutter),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    PhoneCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(ScootIcons.lock, size: 28, color: c.text2),
                          const SizedBox(height: 12),
                          Semantics(
                            header: true,
                            child: Text(
                              title,
                              style: ScootType.h1.copyWith(color: c.ink),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            message,
                            style: ScootType.body.copyWith(color: c.text2),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (primaryLabel != null)
                      FilledButton(
                        onPressed: primaryAction,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(
                            ScootSize.primaryButton,
                          ),
                        ),
                        child: Text(primaryLabel!),
                      ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: onSignOut,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(
                          ScootSize.primaryButton,
                        ),
                      ),
                      child: const Text('Sign out'),
                    ),
                    const SizedBox(height: 8),
                    const LegalDocumentLinks(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OfflineSessionBanner extends StatelessWidget {
  const OfflineSessionBanner({
    super.key,
    required this.verifiedAt,
    required this.onRetry,
    required this.child,
  });

  final DateTime? verifiedAt;
  final VoidCallback onRetry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final DateTime? local = verifiedAt?.toLocal();
    final String verifiedLabel = local == null
        ? 'recently'
        : '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')} '
              '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    final ScootColors c = ScootColors.of(context);
    return Column(
      children: <Widget>[
        Material(
          color: c.page,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                ScootSpace.phoneGutter,
                8,
                ScootSpace.phoneGutter,
                0,
              ),
              child: ScootNotice(
                tone: ScootTone.warning,
                icon: ScootIcons.cloudOff,
                title: 'Offline access',
                message:
                    'Account last verified $verifiedLabel. Saved work stays available and syncs later.',
                actionLabel: 'Retry verification',
                onAction: onRetry,
                actionBelow: true,
                liveRegion: true,
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
