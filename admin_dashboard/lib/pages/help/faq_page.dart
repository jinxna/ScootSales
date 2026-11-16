import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:scoot_help/scoot_help.dart';

import '../../models/user_profile.dart';

FaqAudience faqAudienceFor(UserProfile profile) {
  if (profile.isBranchManager) return FaqAudience.branchManager;
  if (profile.isSupervisor) return FaqAudience.supervisor;
  return FaqAudience.admin;
}

Future<void> showFaq(
  BuildContext context,
  UserProfile profile, {
  String? initialId,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880, maxHeight: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 8, 0),
                child: IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  icon: const Icon(ScootIcons.close),
                ),
              ),
            ),
            Expanded(
              child: FaqPage(profile: profile, initialId: initialId),
            ),
          ],
        ),
      ),
    ),
  );
}

class FaqPage extends StatefulWidget {
  const FaqPage({super.key, required this.profile, this.initialId});

  final UserProfile profile;
  final String? initialId;

  @override
  State<FaqPage> createState() => _FaqPageState();
}

class _FaqPageState extends State<FaqPage> {
  final TextEditingController _search = TextEditingController();
  final Map<String, GlobalKey> _itemKeys = <String, GlobalKey>{};
  late final Set<String> _open = <String>{
    if (widget.initialId != null) widget.initialId!,
  };
  String _query = '';

  List<FaqItem> get _audienceItems {
    final FaqAudience audience = faqAudienceFor(widget.profile);
    return faqItems
        .where((FaqItem item) => item.audiences.contains(audience))
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    final String? id = widget.initialId;
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? target = _itemKeys[id]?.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(target, duration: Duration.zero);
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<FaqItem> all = _audienceItems;
    final List<FaqItem> shown = all
        .where((FaqItem item) => item.matches(_query))
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: <Widget>[
        ScootPageHeader(title: 'Help and questions', fact: '${all.length} answers'),
        const SizedBox(height: ScootSpace.lg),
        TextField(
          controller: _search,
          onChanged: (String value) => setState(() => _query = value),
          decoration: const InputDecoration(
            labelText: 'Search questions',
            prefixIcon: Icon(ScootIcons.search),
          ),
        ),
        const SizedBox(height: ScootSpace.blockGap),
        if (shown.isEmpty)
          const ScootEmptyState(
            title: 'No answers found',
            message: 'Try other words. Or ask your administrator.',
          )
        else
          for (final String topic in faqTopics)
            ..._topic(topic, shown),
      ],
    );
  }

  List<Widget> _topic(String topic, List<FaqItem> shown) {
    final List<FaqItem> items = shown
        .where((FaqItem item) => item.topic == topic)
        .toList(growable: false);
    if (items.isEmpty) return const <Widget>[];
    return <Widget>[
      ScootCard(
        title: topic,
        padding: EdgeInsets.zero,
        child: Column(
          children: <Widget>[
            for (final FaqItem item in items) _question(item),
          ],
        ),
      ),
      const SizedBox(height: ScootSpace.blockGap),
    ];
  }

  Widget _question(FaqItem item) {
    final ScootColors c = ScootColors.of(context);
    final bool open = _open.contains(item.id) || _query.trim().isNotEmpty;
    return KeyedSubtree(
      key: _itemKeys.putIfAbsent(item.id, GlobalKey.new),
      child: Semantics(
        container: true,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: ValueKey<String>('${item.id}-${_query.trim().isNotEmpty}'),
            initiallyExpanded: open,
            onExpansionChanged: (bool value) => setState(() {
              if (value) {
                _open.add(item.id);
              } else {
                _open.remove(item.id);
              }
            }),
            tilePadding: const EdgeInsets.symmetric(horizontal: 20),
            childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            expandedAlignment: Alignment.centerLeft,
            title: Text(
              item.question,
              style: ScootType.bodyStrong.copyWith(color: c.ink),
            ),
            children: <Widget>[
              for (final String line in item.answer)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    line,
                    style: ScootType.body.copyWith(color: c.text2),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
