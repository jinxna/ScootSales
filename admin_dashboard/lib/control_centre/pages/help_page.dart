import 'package:flutter/material.dart';
import 'package:scoot_help/staff_help.dart';

import '../widgets/cc_common.dart';
import '../widgets/cc_shell.dart';

class StaffHelpPage extends StatefulWidget {
  const StaffHelpPage({super.key});

  @override
  State<StaffHelpPage> createState() => _StaffHelpPageState();
}

class _StaffHelpPageState extends State<StaffHelpPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final List<FaqItem> items = <FaqItem>[
      for (final FaqItem item in staffFaqItems)
        if (item.matches(_query)) item,
    ];
    return CcPage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const CcPageHeader('Help'),
          TextField(
            onChanged: (String value) => setState(() => _query = value),
            decoration: const InputDecoration(
              hintText: 'Search the questions',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          if (items.isEmpty)
            const CcEmptyState(
              title: 'No question matches.',
              message: 'Try a different word.',
            ),
          for (final String topic in staffFaqTopics)
            if (items.any((FaqItem item) => item.topic == topic))
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: CcCard(
                  title: topic,
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    children: <Widget>[
                      for (final FaqItem item in items)
                        if (item.topic == topic)
                          ExpansionTile(
                            title: Text(
                              item.question,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Cc.ink,
                              ),
                            ),
                            shape: const Border(),
                            collapsedShape: const Border(),
                            expandedAlignment: Alignment.centerLeft,
                            expandedCrossAxisAlignment:
                                CrossAxisAlignment.start,
                            childrenPadding: const EdgeInsets.fromLTRB(
                              16,
                              0,
                              16,
                              12,
                            ),
                            children: <Widget>[
                              for (final String line in item.answer)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 720,
                                    ),
                                    child: Text(
                                      line,
                                      textAlign: TextAlign.start,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        height: 1.5,
                                        color: Cc.body,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
