import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

typedef ForecastFallback = ({
  bool serviceOnline,
  bool noForecast,
  bool loadFailed,
});

ForecastFallback forecastFallback({
  required bool serviceReady,
  required bool hasSavedCopy,
  required bool readFailed,
}) => (
  serviceOnline: serviceReady,
  noForecast: !hasSavedCopy && !readFailed,
  loadFailed: !hasSavedCopy && readFailed,
);

class ForecastStatusNotices extends StatelessWidget {
  const ForecastStatusNotices({
    super.key,
    required this.toolsEnabled,
    required this.hasForecastingService,
    required this.serviceOnline,
    required this.isAdmin,
    required this.onCheckAgain,
    this.savedForecastLabel,
    this.checking = false,
  });

  final bool toolsEnabled;
  final bool hasForecastingService;
  final bool serviceOnline;
  final bool isAdmin;
  final VoidCallback onCheckAgain;
  final String? savedForecastLabel;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final List<Widget> notices = <Widget>[];
    if (toolsEnabled && !serviceOnline) {
      notices.add(
        ScootCard(
          title: 'The forecasting service is offline',
          trailing: OutlinedButton(
            onPressed: checking ? null : onCheckAgain,
            child: Text(checking ? 'Checking' : 'Check again'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Run forecast and Import Excel need the service on the office PC. Saved forecasts still show when they exist.',
                style: ScootType.body.copyWith(color: c.muted),
              ),
              const SizedBox(height: 10),
              for (final MapEntry<int, String> step in <int, String>{
                1: 'Start the forecasting service on the office PC.',
                2: 'Press Check again.',
                3: 'Press Run forecast.',
              }.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${step.key}. ${step.value}',
                    style: ScootType.body.copyWith(color: c.ink),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    if (savedForecastLabel != null) {
      notices.add(
        ScootNotice(
          tone: ScootTone.neutral,
          icon: ScootIcons.cloudOff,
          title: 'Showing a saved forecast',
          message: '$savedForecastLabel. It is not live.',
        ),
      );
    }
    if (!toolsEnabled && isAdmin && hasForecastingService) {
      notices.add(
        ScootNotice.readOnly(
          message:
              'Run forecast and Import Excel need the forecasting service on the office PC.',
        ),
      );
    }
    if (!toolsEnabled && !isAdmin) {
      notices.add(
        ScootNotice.readOnly(
          message: 'You can view forecasts. Admins run and import them.',
        ),
      );
    }
    if (notices.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < notices.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 12),
          notices[i],
        ],
        const SizedBox(height: 16),
      ],
    );
  }
}

class ForecastLoadFailed extends StatelessWidget {
  const ForecastLoadFailed({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ScootCard(
      child: ScootErrorState(
        title: 'Forecast data not available',
        message: message,
        onRetry: onRetry,
      ),
    );
  }
}

class ForecastUnavailable extends StatelessWidget {
  const ForecastUnavailable({
    super.key,
    required this.loadFailed,
    required this.onRetry,
  });

  final bool loadFailed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (loadFailed) {
      return ForecastLoadFailed(
        message:
            'The forecasts could not be loaded. Check your connection, then try again.',
        onRetry: onRetry,
      );
    }
    return const ScootCard(
      child: ScootEmptyState(
        title: 'No forecast yet',
        message: 'No forecasts have been published for this company yet.',
      ),
    );
  }
}

class ForecastLoading extends StatelessWidget {
  const ForecastLoading({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ScootCard(
      child: ScootLoadingState(
        onRetry: onRetry,
        semanticLabel: 'Loading forecasts',
        skeleton: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < 8; i++)
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
