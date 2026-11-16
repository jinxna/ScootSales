import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import 'frames.dart';

void _noop() {}

void _noopTab(ScootPhoneTab _) {}

const ScootActionBannerData rejectedBanner = ScootActionBannerData(
  priority: ScootBannerPriority.rejectedOrder,
  title: '1 order was rejected',
  message: 'Emart Moyan. No reason given.',
  actionLabel: 'View',
  onAction: _noop,
);

const ScootActionBannerData locationOffBanner = ScootActionBannerData(
  priority: ScootBannerPriority.locationOff,
  title: 'Location is off',
  message: 'Turn on location to check in at a stop.',
  actionLabel: 'Turn on',
  onAction: _noop,
);

const List<ScootActionBannerData> allBanners = <ScootActionBannerData>[
  ScootActionBannerData(
    priority: ScootBannerPriority.companyPaused,
    title: 'Company paused by the office',
    message:
        'Your work stays on this phone. It sends when the company is active again.',
  ),
  locationOffBanner,
  ScootActionBannerData(
    priority: ScootBannerPriority.preciseLocationOff,
    title: 'Precise location is off',
    message: 'Check-ins need precise location.',
    actionLabel: 'Settings',
    onAction: _noop,
  ),
  ScootActionBannerData(
    priority: ScootBannerPriority.workNotStarted,
    title: 'Work not started',
    message: 'Start work to share your location with your team.',
    actionLabel: 'Start',
    onAction: _noop,
  ),
  rejectedBanner,
  ScootActionBannerData(
    priority: ScootBannerPriority.companyActiveAgain,
    title: 'The company is active again',
    message: '2 held orders were sent.',
  ),
  ScootActionBannerData(
    priority: ScootBannerPriority.clockWrong,
    title: 'Phone clock is wrong',
    message: 'Set the date and time to automatic.',
    actionLabel: 'Settings',
    onAction: _noop,
  ),
];

ScootPhoneAppBar homeAppBar({int bell = 1}) {
  return ScootPhoneAppBar(
    title: 'Good evening, E2E',
    subtitle: 'Wednesday, 4 November',
    actions: <Widget>[
      const ScootCopilotPill(onPressed: _noop),
      ScootPhoneAction(
        icon: ScootIcons.notifications,
        label: 'Purchase order follow-ups',
        onPressed: _noop,
        count: bell,
        countLabel: '$bell follow-up',
      ),
    ],
  );
}

Widget _card(BuildContext context, Widget child, {EdgeInsets? padding}) {
  final ScootColors c = ScootColors.of(context);
  return Container(
    padding: padding ?? const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: c.card,
      border: Border.all(color: c.line),
      borderRadius: ScootRadius.cardAll,
    ),
    child: child,
  );
}

Widget _stat(
  BuildContext context,
  String value,
  String label,
  bool brand, {
  bool divider = true,
}) {
  final ScootColors c = ScootColors.of(context);
  return Expanded(
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          left: divider ? BorderSide(color: c.line) : BorderSide.none,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              value,
              key: ValueKey<String>('kpi-$label'),
              style: ScootType.kpi.copyWith(
                fontSize: 22,
                color: brand ? c.brandText : c.ink,
              ),
            ),
            Text(label, style: ScootType.small.copyWith(color: c.text2)),
          ],
        ),
      ),
    ),
  );
}

Widget homeBody(BuildContext context) {
  final ScootColors c = ScootColors.of(context);
  return ListView(
    padding: const EdgeInsets.all(ScootSpace.phoneGutter),
    children: <Widget>[
      _card(
        context,
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _stat(context, '2', 'Outlets', true, divider: false),
              _stat(context, '3', 'Orders today', true),
              _stat(context, '0', 'Visits left', false),
              _stat(context, '0', 'Unsent drafts', false),
            ],
          ),
        ),
        padding: EdgeInsets.zero,
      ),
      const SizedBox(height: 8),
      const ScootSectionHeader(
        title: 'Today',
        actionLabel: 'Planner',
        actionIcon: ScootIcons.calendar,
        onAction: _noop,
      ),
      _card(
        context,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c.brandTint,
                    borderRadius: ScootRadius.controlAll,
                  ),
                  child: Icon(ScootIcons.route, color: c.brandText, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Assigned route',
                        style: ScootType.bodyStrong.copyWith(color: c.ink),
                      ),
                      Text(
                        'Week of 2 Nov · No stops today · Assigned by Supervisor',
                        style: ScootType.small.copyWith(color: c.text2),
                      ),
                    ],
                  ),
                ),
                Icon(ScootIcons.chevronRight, color: c.text2),
              ],
            ),
            Divider(height: 28, color: c.hair),
            Text(
              'No visits planned for today.',
              style: ScootType.bodyStrong.copyWith(color: c.ink),
            ),
            Text(
              'Plan a visit, or check your assigned route for the week.',
              style: ScootType.body.copyWith(color: c.text2),
            ),
          ],
        ),
      ),
    ],
  );
}

Widget phoneHome({
  required ScootSyncStatus sync,
  required ScootGpsStatus gps,
  List<ScootActionBannerData> banners = const <ScootActionBannerData>[
    rejectedBanner,
  ],
  int ordersWaiting = 0,
}) {
  return ScootPhoneScaffold(
    appBar: homeAppBar(),
    statusStrip: ScootStatusStrip(
      sync: sync,
      gps: gps,
      onTap: _noop,
      onRetry: _noop,
    ),
    banner: ScootActionBanner.pick(banners),
    body: const Builder(builder: homeBody),
    primaryAction: const ScootPrimaryActionBar(
      label: 'Plan a visit',
      icon: ScootIcons.add,
      onPressed: _noop,
    ),
    bottomNav: ScootBottomNav(
      current: ScootPhoneTab.home,
      onSelect: _noopTab,
      ordersWaiting: ordersWaiting,
    ),
  );
}

Widget countBody(BuildContext context) {
  final ScootColors c = ScootColors.of(context);
  return ListView(
    padding: const EdgeInsets.all(ScootSpace.phoneGutter),
    children: <Widget>[
      Text('Count the shelf', style: ScootType.section.copyWith(color: c.ink)),
      Text(
        'Enter the boxes on the shelf for each expiry date.',
        style: ScootType.body.copyWith(color: c.text2),
      ),
      const SizedBox(height: 12),
      _card(
        context,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ScootLongText(
              'ORGANIC APPLE CIDER VINEGAR WITH THE MOTHER RAW UNFILTERED (12BTL X 946ML)',
              style: ScootType.bodyStrong.copyWith(color: c.ink),
            ),
            Text.rich(
              const TextSpan(
                children: <InlineSpan>[
                  TextSpan(text: '9555592203502', style: ScootType.mono),
                  TextSpan(text: ' · RM 28.12 a box'),
                ],
              ),
              style: ScootType.small.copyWith(color: c.text2),
            ),
            Divider(height: 24, color: c.hair),
            Text(
              'Boxes on the shelf',
              style: ScootType.smallStrong.copyWith(color: c.ink),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: c.line2),
                    borderRadius: ScootRadius.controlAll,
                  ),
                  child: ClipRRect(
                    borderRadius: ScootRadius.controlAll,
                    child: IntrinsicHeight(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          const IconButton(
                            onPressed: _noop,
                            tooltip: 'One box fewer',
                            icon: Icon(ScootIcons.remove),
                          ),
                          VerticalDivider(width: 1, color: c.line2),
                          SizedBox(
                            width: 44,
                            child: Center(
                              child: Text(
                                '0',
                                style: ScootType.bodyStrong.copyWith(
                                  color: c.ink,
                                  fontFeatures: ScootType.tabular,
                                ),
                              ),
                            ),
                          ),
                          VerticalDivider(width: 1, color: c.line2),
                          const IconButton(
                            onPressed: _noop,
                            tooltip: 'One box more',
                            icon: Icon(ScootIcons.add),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _noop,
                    icon: const Icon(ScootIcons.calendar, size: 18),
                    label: const Text('Expiry date'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}

Widget signOffBody(BuildContext context) {
  final ScootColors c = ScootColors.of(context);
  return ListView(
    padding: const EdgeInsets.all(ScootSpace.phoneGutter),
    children: <Widget>[
      Text('Sign-off', style: ScootType.section.copyWith(color: c.ink)),
      Text(
        'The outlet signs for the order on this phone.',
        style: ScootType.body.copyWith(color: c.text2),
      ),
      const SizedBox(height: 12),
      _card(
        context,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Emart Moyan',
              style: ScootType.bodyStrong.copyWith(color: c.ink),
            ),
            Text(
              '3 products · RM 85.25',
              style: ScootType.small.copyWith(color: c.text2),
            ),
            Divider(height: 24, color: c.hair),
            Text(
              'Signature',
              style: ScootType.smallStrong.copyWith(color: c.ink),
            ),
            const SizedBox(height: 8),
            Container(
              height: 120,
              decoration: BoxDecoration(
                border: Border.all(color: c.line2),
                borderRadius: ScootRadius.controlAll,
              ),
              alignment: Alignment.center,
              child: Text(
                'Sign here',
                style: ScootType.body.copyWith(color: c.muted),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

Widget visitFlow({
  required int step,
  required Widget primary,
  WidgetBuilder body = countBody,
  ScootSyncStatus sync = const ScootSyncStatus.synced('18:34'),
}) {
  return ScootPhoneScaffold(
    appBar: const ScootPhoneAppBar(
      title: 'Emart Moyan',
      subtitle: 'Moyan, Kuching',
      onBack: _noop,
      actions: <Widget>[
        ScootPhoneAction(
          icon: ScootIcons.scanBarcode,
          label: 'Scan barcode',
          onPressed: _noop,
        ),
        ScootCopilotPill(onPressed: _noop),
      ],
    ),
    stepBar: ScootStepBar(current: step),
    statusStrip: ScootStatusStrip(
      sync: sync,
      gps: ScootGpsStatus.fix(8),
      onTap: _noop,
    ),
    body: Builder(builder: body),
    primaryAction: primary,
  );
}

Widget _listScene(BuildContext context, String title, List<Widget> children) {
  return ScootPhoneScaffold(
    appBar: ScootPhoneAppBar(title: title, onBack: _noop),
    body: ListView(
      padding: const EdgeInsets.symmetric(vertical: ScootSpace.phoneGutter),
      children: children,
    ),
  );
}

Widget _label(BuildContext context, String text) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Text(
      text,
      style: ScootType.caption.copyWith(color: ScootColors.of(context).muted),
    ),
  );
}

Widget stripsScene(BuildContext context) {
  final List<(String, ScootSyncStatus, ScootGpsStatus)> items =
      <(String, ScootSyncStatus, ScootGpsStatus)>[
        (
          'Synced, GPS good',
          const ScootSyncStatus.synced('18:34'),
          ScootGpsStatus.fix(8),
        ),
        (
          'Sending, GPS weak',
          const ScootSyncStatus.sending(2),
          ScootGpsStatus.fix(65),
        ),
        (
          'Offline, GPS off',
          const ScootSyncStatus.offline('2 orders kept on this phone.'),
          const ScootGpsStatus.off(),
        ),
        (
          'Saved data, work not started',
          const ScootSyncStatus.cached('18:02'),
          const ScootGpsStatus.workNotStarted(),
        ),
        (
          'Accuracy unknown (GPS-08)',
          const ScootSyncStatus.synced('18:34'),
          ScootGpsStatus.fix(0),
        ),
        (
          'Still loading after 10 s, Retry',
          const ScootSyncStatus.stillLoading(),
          ScootGpsStatus.fix(8),
        ),
      ];
  return _listScene(context, 'Status strip', <Widget>[
    for (final (String, ScootSyncStatus, ScootGpsStatus) item
        in items) ...<Widget>[
      _label(context, item.$1),
      ScootStatusStrip(
        sync: item.$2,
        gps: item.$3,
        onTap: _noop,
        onRetry: _noop,
      ),
    ],
  ]);
}

Widget bannersScene(BuildContext context) {
  return _listScene(context, 'Action banners', <Widget>[
    for (final ScootActionBannerData data in allBanners)
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: ScootActionBanner(data: data),
      ),
  ]);
}

Widget navScene(BuildContext context) {
  return _listScene(context, 'Bottom navigation', <Widget>[
    for (final ScootPhoneTab tab in ScootPhoneTab.values) ...<Widget>[
      _label(context, '${ScootBottomNav.labels[tab]} active'),
      MediaQuery.removePadding(
        context: context,
        removeBottom: true,
        child: ScootBottomNav(
          current: tab,
          onSelect: _noopTab,
          ordersWaiting: tab == ScootPhoneTab.orders ? 2 : 0,
        ),
      ),
    ],
    _label(context, 'Step bar: Select, Count, Sign'),
    const ScootStepBar(current: 0),
    const SizedBox(height: 8),
    const ScootStepBar(current: 1),
    const SizedBox(height: 8),
    const ScootStepBar(current: 2),
  ]);
}

Widget longNamesScene(BuildContext context) {
  final ScootColors c = ScootColors.of(context);
  const List<(String, String)> rows = <(String, String)>[
    ('Choice Supermarket Tabuan Jaya', 'Tabuan Jaya, Kuching'),
    (
      'Choice Supermarket Tabuan Jaya Commercial Centre Lot 1234 Jalan Wan Alwi Off Jalan Song',
      'Tabuan Jaya, Kuching',
    ),
    (
      'Bintang Fresh Stutong Baru Sdn Bhd (Main Entrance Receiving Bay)',
      'Stutong, Kuching',
    ),
    ('Emart Moyan', 'Moyan, Kuching'),
  ];
  return ScootPhoneScaffold(
    appBar: const ScootPhoneAppBar(title: 'Route'),
    statusStrip: ScootStatusStrip(
      sync: const ScootSyncStatus.synced('18:34'),
      gps: ScootGpsStatus.fix(8),
      onTap: _noop,
    ),
    body: ListView(
      padding: const EdgeInsets.all(ScootSpace.phoneGutter),
      children: <Widget>[
        for (int i = 0; i < rows.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _card(
              context,
              Row(
                children: <Widget>[
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: c.brandTint,
                    child: Text(
                      '${i + 1}',
                      style: ScootType.smallStrong.copyWith(color: c.brandText),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        ScootLongText(
                          rows[i].$1,
                          style: ScootType.bodyStrong.copyWith(color: c.ink),
                        ),
                        Text(
                          rows[i].$2,
                          style: ScootType.small.copyWith(color: c.text2),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  i == 0
                      ? const ScootBadge(
                          label: 'Completed',
                          tone: ScootTone.success,
                          icon: ScootIcons.check,
                        )
                      : const ScootBadge(label: 'Next'),
                ],
              ),
            ),
          ),
      ],
    ),
    bottomNav: const ScootBottomNav(
      current: ScootPhoneTab.route,
      onSelect: _noopTab,
    ),
  );
}

Widget phoneStatesScene(BuildContext context) {
  return ScootPhoneScaffold(
    appBar: const ScootPhoneAppBar(title: 'Orders'),
    statusStrip: ScootStatusStrip(
      sync: const ScootSyncStatus.cached('18:02'),
      gps: ScootGpsStatus.fix(8),
      onTap: _noop,
    ),
    body: ListView(
      padding: const EdgeInsets.all(ScootSpace.phoneGutter),
      children: <Widget>[
        _label(context, 'Loading: skeleton in final size'),
        _card(
          context,
          const SizedBox(
            height: 64,
            child: ScootSkeletonLines(widthFactors: <double>[0.8, 0.5, 0.3]),
          ),
        ),
        _label(context, 'Still loading after 10 s'),
        _card(
          context,
          const ScootLoadingState(
            onRetry: _noop,
            stillLoadingAfter: Duration.zero,
            message: 'Still loading. Showing saved data.',
            skeleton: ScootSkeletonLines(widthFactors: <double>[0.8, 0.5, 0.3]),
          ),
        ),
        _label(context, 'Empty'),
        _card(
          context,
          const ScootEmptyState(
            icon: ScootIcons.orders,
            title: 'No orders yet',
            message: 'Orders you submit show here.',
          ),
          padding: EdgeInsets.zero,
        ),
        _label(context, 'Error'),
        _card(
          context,
          const ScootErrorState(onRetry: _noop),
          padding: EdgeInsets.zero,
        ),
      ],
    ),
    bottomNav: const ScootBottomNav(
      current: ScootPhoneTab.orders,
      onSelect: _noopTab,
      ordersWaiting: 2,
    ),
  );
}

final List<GalleryScene> phoneScenes = <GalleryScene>[
  GalleryScene(
    id: 'phone-home-synced',
    title: 'Phone · Home, synced, rejected-order banner',
    surface: GallerySurface.phone,
    builder: (BuildContext context) => phoneHome(
      sync: const ScootSyncStatus.synced('18:34'),
      gps: ScootGpsStatus.fix(8),
    ),
  ),
  GalleryScene(
    id: 'phone-home-offline',
    title: 'Phone · Home, offline, banner priority picks location off',
    surface: GallerySurface.phone,
    builder: (BuildContext context) => phoneHome(
      sync: const ScootSyncStatus.offline('2 orders kept on this phone.'),
      gps: ScootGpsStatus.fix(65),
      banners: const <ScootActionBannerData>[rejectedBanner, locationOffBanner],
      ordersWaiting: 2,
    ),
  ),
  GalleryScene(
    id: 'phone-home-still-loading',
    title: 'Phone · Home, still loading with Retry',
    surface: GallerySurface.phone,
    builder: (BuildContext context) => phoneHome(
      sync: const ScootSyncStatus.stillLoading(),
      gps: ScootGpsStatus.fix(8),
      banners: const <ScootActionBannerData>[],
    ),
  ),
  GalleryScene(
    id: 'phone-visit-count',
    title: 'Phone · visit flow step 2, long product name',
    surface: GallerySurface.phone,
    builder: (BuildContext context) => visitFlow(
      step: 1,
      primary: const ScootPrimaryActionBar(
        label: 'Continue to sign-off',
        onPressed: _noop,
        note: 'Saved on this phone · 18:33',
        aboveHomeIndicator: true,
      ),
    ),
  ),
  GalleryScene(
    id: 'phone-visit-sign-disabled',
    title: 'Phone · visit flow step 3, primary disabled with reason',
    surface: GallerySurface.phone,
    builder: (BuildContext context) => visitFlow(
      step: 2,
      body: signOffBody,
      sync: const ScootSyncStatus.sending(1),
      primary: const ScootPrimaryActionBar(
        label: 'Submit order',
        onPressed: null,
        disabledReason: 'Grocery needs a signature.',
        secondaryLabel: 'Save draft',
        onSecondary: _noop,
        aboveHomeIndicator: true,
      ),
    ),
  ),
  const GalleryScene(
    id: 'phone-status-strips',
    title: 'Phone · status strip, every sync and GPS state',
    surface: GallerySurface.phone,
    builder: stripsScene,
  ),
  const GalleryScene(
    id: 'phone-action-banners',
    title: 'Phone · action banners in priority order',
    surface: GallerySurface.phone,
    builder: bannersScene,
  ),
  const GalleryScene(
    id: 'phone-navigation',
    title: 'Phone · bottom navigation and step bar',
    surface: GallerySurface.phone,
    height: 1000,
    builder: navScene,
  ),
  const GalleryScene(
    id: 'phone-long-names',
    title: 'Phone · long names, two lines then ellipsis',
    surface: GallerySurface.phone,
    builder: longNamesScene,
  ),
  const GalleryScene(
    id: 'phone-states',
    title: 'Phone · loading, still loading, empty, error',
    surface: GallerySurface.phone,
    height: 1000,
    builder: phoneStatesScene,
  ),
  GalleryScene(
    id: 'phone-home-dark',
    title: 'Phone · Home, dark mode',
    surface: GallerySurface.phone,
    brightness: Brightness.dark,
    builder: (BuildContext context) => phoneHome(
      sync: const ScootSyncStatus.sending(2),
      gps: ScootGpsStatus.fix(8),
    ),
  ),
];
