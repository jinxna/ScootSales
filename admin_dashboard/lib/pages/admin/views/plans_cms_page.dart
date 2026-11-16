import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../services/platform_api_client.dart';
import '../../../theme/dso_theme.dart';
import '../../../widgets/slow_loading.dart';

class PlansCmsPage extends StatefulWidget {
  const PlansCmsPage({super.key, this.client});

  final PlatformApiClient? client;

  @override
  State<PlansCmsPage> createState() => _PlansCmsPageState();
}

class _PlansCmsPageState extends State<PlansCmsPage> {
  late final PlatformApiClient _api = widget.client ?? PlatformApiClient();
  PlanCatalogue? _catalogue;
  String _error = '';
  bool _loading = true;
  bool _yearly = false;
  String? _sendingPlanId;
  String _notice = '';

  static const Map<String, String> _poolNouns = <String, String>{
    'salesmen': 'salesmen',
    'supervisors': 'supervisors',
    'admins': 'admins',
    'branchManagers': 'branch managers',
    'managers': 'managers',
    'products': 'products',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final PlanCatalogue catalogue = await _api.getPlans();
      if (!mounted) return;
      setState(() {
        _catalogue = catalogue;
        _yearly = catalogue.currentInterval == 'yearly';
      });
    } on PlatformApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _choose(PlanOffer plan) async {
    if (_sendingPlanId != null || !plan.canRequest) return;
    setState(() {
      _sendingPlanId = plan.planId;
      _notice = '';
    });
    try {
      await _api.requestPlan(
        plan.planId,
        interval: _yearly ? 'yearly' : 'monthly',
        idempotencyKey: const Uuid().v4(),
      );
      if (!mounted) return;
      setState(
        () => _notice =
            'Request sent. The Scoot Sales team will contact you to arrange payment.',
      );
    } on PlatformApiException catch (error) {
      if (!mounted) return;
      setState(() => _notice = error.message);
    } finally {
      if (mounted) setState(() => _sendingPlanId = null);
    }
  }

  int? _saving(PlanCatalogue catalogue) {
    int? best;
    for (final PlanOffer plan in catalogue.plans) {
      final num? monthly = plan.monthly;
      final num? yearly = plan.yearly;
      if (monthly == null || yearly == null || monthly <= 0) continue;
      final int percent = ((1 - yearly / (monthly * 12)) * 100).round();
      if (percent > 0 && (best == null || percent > best)) best = percent;
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final PlanCatalogue? catalogue = _catalogue;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Choose a plan',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: SlowLoading(),
            )
          else if (catalogue == null)
            _errorBox()
          else ...<Widget>[
            _intervalSwitch(catalogue),
            if (_notice.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  _notice,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: DsoTokens.green550,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            _cards(catalogue),
            if (catalogue.plans.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                'To subscribe, request a plan. Our team contacts you to arrange payment.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.dso.muted),
              ),
              const SizedBox(height: 32),
              _comparison(catalogue),
              const SizedBox(height: 24),
            ],
          ],
        ],
      ),
    );
  }

  Widget _errorBox() => Column(
    children: <Widget>[
      Semantics(
        liveRegion: true,
        child: Text(
          _error.isEmpty ? 'Could not load the plans.' : _error,
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
      const SizedBox(height: 12),
      OutlinedButton(onPressed: _load, child: const Text('Try again')),
    ],
  );

  Widget _intervalSwitch(PlanCatalogue catalogue) {
    final int? saving = _saving(catalogue);
    final bool priced = catalogue.plans.any(
      (PlanOffer plan) => plan.monthly != null || plan.yearly != null,
    );
    if (!priced) return const SizedBox.shrink();
    return Center(
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const <ButtonSegment<bool>>[
              ButtonSegment<bool>(value: false, label: Text('Monthly')),
              ButtonSegment<bool>(value: true, label: Text('Yearly')),
            ],
            selected: <bool>{_yearly},
            onSelectionChanged: (Set<bool> value) =>
                setState(() => _yearly = value.single),
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: DsoTokens.green550,
              selectedForegroundColor: Colors.white,
            ),
          ),
          if (saving != null)
            Text(
              'Save up to $saving%',
              style: const TextStyle(
                color: DsoTokens.green550,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }

  Widget _contactSalesPanel() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: DsoTokens.green550),
        ),
        child: Column(
          children: <Widget>[
            const Icon(
              Icons.support_agent_outlined,
              size: 32,
              color: DsoTokens.green550,
            ),
            const SizedBox(height: 8),
            Text(
              'Contact Scoot Sales to change your package',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Package changes for this workspace are arranged with your Scoot Sales contact. Contact sales to move to another package; prices are shared when you contact sales.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.dso.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cards(PlanCatalogue catalogue) {
    if (catalogue.plans.isEmpty) return _contactSalesPanel();
    final bool noPlanCanBeRequested = catalogue.plans.every(
      (PlanOffer plan) => !plan.canRequest,
    );
    final Widget grid = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const double gap = 16;
        final double width = constraints.maxWidth;
        final int fit = width >= 1100 ? 4 : (width >= 700 ? 2 : 1);
        final int columns = catalogue.plans.length < fit
            ? catalogue.plans.length
            : fit;
        final double cardWidth = (width - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap * 2,
          children: <Widget>[
            for (int index = 0; index < catalogue.plans.length; index++)
              SizedBox(
                width: cardWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _card(catalogue, catalogue.plans[index]),
                    const SizedBox(height: 16),
                    _included(
                      catalogue,
                      catalogue.plans[index],
                      index == 0 ? null : catalogue.plans[index - 1],
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
    if (!noPlanCanBeRequested) return grid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _contactSalesPanel(),
        const SizedBox(height: 20),
        grid,
      ],
    );
  }

  Widget _card(PlanCatalogue catalogue, PlanOffer plan) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String interval = _yearly ? 'yearly' : 'monthly';
    final bool onThisPlan = catalogue.currentPlanId == plan.planId;
    final bool current = onThisPlan && catalogue.currentInterval == interval;
    final bool sending = _sendingPlanId == plan.planId;
    final bool unavailable = !current && !plan.canRequest;
    final String? allowance = _mainAllowance(plan);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: onThisPlan ? DsoTokens.green550 : scheme.outlineVariant,
          width: onThisPlan ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            plan.name,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (plan.tagline.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(plan.tagline, style: TextStyle(color: context.dso.muted)),
          ],
          const SizedBox(height: 16),
          _price(plan),
          if (allowance != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              allowance,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 16),
          if (current)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: DsoTokens.green550),
              ),
              child: const Text(
                'Current plan',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: DsoTokens.green550,
                ),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: Semantics(
                button: true,
                label: unavailable
                    ? '${plan.name}: ${plan.requestReason}'
                    : 'Request the ${plan.name} plan',
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: DsoTokens.green550,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: unavailable || _sendingPlanId != null
                      ? null
                      : () => _choose(plan),
                  child: sending
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          unavailable ? 'Upgrade only' : 'Request this plan',
                        ),
                ),
              ),
            ),
          if (unavailable && plan.requestReason.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              plan.requestReason,
              style: TextStyle(color: context.dso.muted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _price(PlanOffer plan) {
    final num? monthly = plan.monthly;
    final num? yearly = plan.yearly;
    final num? shown = _yearly
        ? (yearly == null ? null : yearly / 12)
        : monthly;
    if (shown == null) {
      return const Text(
        'Talk to us',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      );
    }
    final String code = plan.currency.isEmpty ? '' : '${plan.currency} ';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'From $code${_money(shown)} per month',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        if (_yearly && yearly != null)
          Text(
            'Billed yearly $code${_money(yearly)}',
            style: TextStyle(color: context.dso.muted),
          ),
      ],
    );
  }

  String? _mainAllowance(PlanOffer plan) {
    final List<String> parts = <String>[];
    int seats = 0;
    bool seatsUnlimited = false;
    bool hasSeats = false;
    for (final MapEntry<String, int?> limit in plan.limits.entries) {
      if (limit.key == 'products' || !_poolNouns.containsKey(limit.key)) {
        continue;
      }
      hasSeats = true;
      final int? value = limit.value;
      if (value == null) {
        seatsUnlimited = true;
      } else {
        seats += value;
      }
    }
    if (hasSeats) {
      parts.add(seatsUnlimited ? 'Unlimited seats' : '$seats seats');
    }
    if (plan.limits.containsKey('products')) {
      final int? products = plan.limits['products'];
      parts.add(products == null ? 'Unlimited products' : '$products products');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  List<String> _capabilities(PlanCatalogue catalogue, PlanOffer? plan) =>
      plan == null
      ? const <String>[]
      : <String>[
          ...?catalogue.editionFeatures[plan.edition],
          ...plan.highlights,
        ];

  List<String> _added(
    PlanCatalogue catalogue,
    PlanOffer plan,
    PlanOffer? previous,
  ) {
    final List<String> items = <String>[];
    final List<String> before = _capabilities(catalogue, previous);
    for (final String capability in _capabilities(catalogue, plan)) {
      if (!before.contains(capability)) items.add(capability);
    }
    for (final String key in _poolNouns.keys) {
      if (!plan.limits.containsKey(key)) continue;
      if (previous != null &&
          previous.limits.containsKey(key) &&
          previous.limits[key] == plan.limits[key]) {
        continue;
      }
      items.add(_limitText(key, plan.limits[key]));
    }
    return items;
  }

  Widget _included(
    PlanCatalogue catalogue,
    PlanOffer plan,
    PlanOffer? previous,
  ) {
    final List<String> items = _added(catalogue, plan, previous);
    final String heading = previous == null
        ? 'Features included in ${plan.name}:'
        : items.isEmpty
        ? 'Everything in ${previous.name}.'
        : 'Everything in ${previous.name}, plus:';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(heading, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        for (final String item in items) _checkRow(item),
      ],
    );
  }

  Widget _checkRow(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Icon(Icons.check, size: 18, color: DsoTokens.green550),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );

  Widget _comparison(PlanCatalogue catalogue) {
    final List<PlanOffer> plans = catalogue.plans;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<String> allowanceKeys = <String>[
      for (final String key in _poolNouns.keys)
        if (plans.any((PlanOffer plan) => plan.limits.containsKey(key))) key,
    ];
    final List<String> featureNames = <String>[];
    for (final List<String> labels in catalogue.editionFeatures.values) {
      for (final String label in labels) {
        if (!featureNames.contains(label)) featureNames.add(label);
      }
    }
    for (final PlanOffer plan in plans) {
      for (final String highlight in plan.highlights) {
        if (!featureNames.contains(highlight)) featureNames.add(highlight);
      }
    }
    final bool showEdition = plans.any(
      (PlanOffer plan) => plan.edition.isNotEmpty,
    );
    TableRow section(String label) => TableRow(
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest),
      children: <Widget>[
        _cell(
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          alignment: Alignment.centerLeft,
        ),
        for (int i = 0; i < plans.length; i++) _cell(const SizedBox.shrink()),
      ],
    );
    TableRow row(String label, Widget Function(PlanOffer plan) value) =>
        TableRow(
          children: <Widget>[
            _cell(Text(label), alignment: Alignment.centerLeft),
            for (final PlanOffer plan in plans) _cell(value(plan)),
          ],
        );
    final List<TableRow> rows = <TableRow>[
      TableRow(
        children: <Widget>[
          _cell(const SizedBox.shrink()),
          for (final PlanOffer plan in plans)
            _cell(
              Text(
                plan.name,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
        ],
      ),
      if (allowanceKeys.isNotEmpty) section('Allowances'),
      for (final String key in allowanceKeys)
        row(
          _capitalised(_poolNouns[key] ?? key),
          (PlanOffer plan) => !plan.limits.containsKey(key)
              ? _dash()
              : Text(
                  plan.limits[key] == null
                      ? 'Unlimited'
                      : '${plan.limits[key]}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
        ),
      if (showEdition || featureNames.isNotEmpty) section('Features'),
      if (showEdition)
        row(
          'Edition',
          (PlanOffer plan) =>
              plan.edition.isEmpty ? _dash() : Text(_capitalised(plan.edition)),
        ),
      for (final String name in featureNames)
        row(
          name,
          (PlanOffer plan) =>
              _capabilities(catalogue, plan).contains(name) ? _tick() : _dash(),
        ),
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double needed = 240.0 + 140.0 * plans.length;
        final double width = constraints.maxWidth > needed
            ? constraints.maxWidth
            : needed;
        final Map<int, TableColumnWidth> widths = <int, TableColumnWidth>{
          0: const FlexColumnWidth(2),
          for (int i = 1; i <= plans.length; i++) i: const FlexColumnWidth(1),
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Compare plans',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: scheme.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: width,
                  child: Table(
                    columnWidths: widths,
                    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                    border: TableBorder(
                      horizontalInside: BorderSide(
                        color: scheme.outlineVariant,
                      ),
                    ),
                    children: rows,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _cell(Widget child, {Alignment alignment = Alignment.center}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Align(alignment: alignment, child: child),
      );

  Widget _tick() => Semantics(
    label: 'Included',
    excludeSemantics: true,
    child: const Icon(Icons.check, size: 20, color: DsoTokens.green550),
  );

  Widget _dash() => Semantics(
    label: 'Not included',
    excludeSemantics: true,
    child: Text('—', style: TextStyle(color: context.dso.muted)),
  );

  String _limitText(String pool, int? limit) {
    final String noun = _poolNouns[pool] ?? pool;
    return limit == null ? 'No limit on $noun' : 'Up to $limit $noun';
  }

  static String _capitalised(String text) =>
      text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

  static String _money(num value) {
    final double rounded = (value * 100).roundToDouble() / 100;
    return rounded == rounded.truncateToDouble()
        ? rounded.toStringAsFixed(0)
        : rounded.toStringAsFixed(2);
  }
}
