import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

class PhoneCard extends StatelessWidget {
  const PhoneCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.tone,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final ScootTone? tone;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final ScootToneColors? t = tone == null ? null : c.tone(tone!);
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: t?.background ?? c.card,
        border: Border.all(color: t?.border ?? c.line),
        borderRadius: ScootRadius.cardAll,
      ),
      child: child,
    );
  }
}

class PhoneSectionTitle extends StatelessWidget {
  const PhoneSectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                text,
                style: ScootType.section.copyWith(
                  color: ScootColors.of(context).ink,
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class PhoneRow extends StatelessWidget {
  const PhoneRow({
    super.key,
    required this.label,
    this.value,
    this.valueWidget,
    this.mono = false,
    this.tone,
  });

  final String label;
  final String? value;
  final Widget? valueWidget;
  final bool mono;
  final ScootTone? tone;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final Color color = tone == null ? c.ink : c.tone(tone!).noteText;
    final TextStyle base = mono ? ScootType.mono : ScootType.bodyStrong;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 104,
            child: Text(label, style: ScootType.small.copyWith(color: c.text2)),
          ),
          Expanded(
            child:
                valueWidget ??
                Text(
                  value ?? '',
                  textAlign: TextAlign.right,
                  style: base.copyWith(color: color),
                ),
          ),
        ],
      ),
    );
  }
}

class PhoneDivider extends StatelessWidget {
  const PhoneDivider({super.key});

  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, color: ScootColors.of(context).line);
}

class PhoneListSkeleton extends StatelessWidget {
  const PhoneListSkeleton({super.key, this.rows = 5});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(ScootSpace.phoneGutter),
      children: <Widget>[
        for (int i = 0; i < rows; i++)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: PhoneCard(
              child: ScootSkeletonLines(widthFactors: <double>[0.6, 0.9, 0.4]),
            ),
          ),
      ],
    );
  }
}

class PhoneStateBody extends StatelessWidget {
  const PhoneStateBody({
    super.key,
    required this.onRetry,
    this.loading = false,
    this.error = false,
    this.empty = false,
    this.errorTitle = 'This could not load',
    this.emptyTitle = 'Nothing here yet',
    this.emptyMessage,
    this.emptyIcon = ScootIcons.inbox,
    this.emptyAction,
    this.skeletonRows = 5,
    this.child,
  });

  final VoidCallback onRetry;
  final bool loading;
  final bool error;
  final bool empty;
  final String errorTitle;
  final String emptyTitle;
  final String? emptyMessage;
  final IconData emptyIcon;
  final Widget? emptyAction;
  final int skeletonRows;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (error) {
      return Center(
        child: SingleChildScrollView(
          child: ScootErrorState(title: errorTitle, onRetry: onRetry),
        ),
      );
    }
    if (loading) {
      return ScootLoadingState(
        skeleton: PhoneListSkeleton(rows: skeletonRows),
        onRetry: onRetry,
      );
    }
    if (empty) {
      return Center(
        child: SingleChildScrollView(
          child: ScootEmptyState(
            icon: emptyIcon,
            title: emptyTitle,
            message: emptyMessage,
            action: emptyAction,
          ),
        ),
      );
    }
    return child ?? const SizedBox.shrink();
  }
}
