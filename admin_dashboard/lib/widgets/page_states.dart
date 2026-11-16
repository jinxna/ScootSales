import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

class PageSkeleton extends StatelessWidget {
  const PageSkeleton({super.key, required this.onRetry, this.rows = 6});

  final VoidCallback onRetry;
  final int rows;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: ScootLoadingState(
        onRetry: onRetry,
        skeleton: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < rows; i++)
              const Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: ScootSkeleton(height: 14),
              ),
          ],
        ),
      ),
    );
  }
}

bool isPermissionDenied(Object? error) =>
    error is FirebaseException && error.code == 'permission-denied';

class PageErrorState extends StatelessWidget {
  const PageErrorState({
    super.key,
    required this.error,
    required this.onRetry,
    this.title = 'This could not load',
  });

  final Object? error;
  final VoidCallback onRetry;
  final String title;

  @override
  Widget build(BuildContext context) {
    if (isPermissionDenied(error)) {
      return ScootEmptyState(
        icon: ScootIcons.lock,
        title: 'You cannot open this page',
        message: 'Your role does not include it. Ask an administrator.',
      );
    }
    return ScootErrorState(title: title, onRetry: onRetry);
  }
}

class OfflineNotice extends StatelessWidget {
  const OfflineNotice({super.key, this.what = 'saved data'});

  final String what;

  @override
  Widget build(BuildContext context) {
    return ScootNotice(
      tone: ScootTone.neutral,
      icon: ScootIcons.cloudOff,
      title: 'Offline',
      message: 'Showing $what. New changes appear when the connection returns.',
      liveRegion: true,
    );
  }
}
