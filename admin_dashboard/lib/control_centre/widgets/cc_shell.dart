import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../staff_api_client.dart';
import 'cc_common.dart';

enum CcSection {
  inbox,
  companies,
  onboarding,
  invoices,
  payments,
  packages,
  staff,
  audit,
  settings,
  account,
  newCompany,
  supportHome,
  help,
}

String sectionLabel(CcSection section) => switch (section) {
  CcSection.inbox => 'Inbox',
  CcSection.companies => 'Companies',
  CcSection.onboarding => 'Onboarding',
  CcSection.invoices => 'Invoices',
  CcSection.payments => 'Payments',
  CcSection.packages => 'Packages',
  CcSection.staff => 'Staff and access',
  CcSection.audit => 'Audit log',
  CcSection.settings => 'Settings',
  CcSection.account => 'My account',
  CcSection.newCompany => 'New company',
  CcSection.supportHome => 'Support',
  CcSection.help => 'Help',
};

IconData _icon(CcSection section) => switch (section) {
  CcSection.inbox => Icons.inbox_outlined,
  CcSection.companies => Icons.apartment_outlined,
  CcSection.onboarding => Icons.checklist_outlined,
  CcSection.invoices => Icons.receipt_long_outlined,
  CcSection.payments => Icons.payments_outlined,
  CcSection.packages => Icons.inventory_2_outlined,
  CcSection.staff => Icons.group_outlined,
  CcSection.audit => Icons.verified_user_outlined,
  CcSection.settings => Icons.settings_outlined,
  CcSection.supportHome => Icons.support_agent_outlined,
  CcSection.help => Icons.help_outline,
  _ => Icons.circle_outlined,
};

const List<CcSection> _workOrder = <CcSection>[
  CcSection.inbox,
  CcSection.companies,
  CcSection.onboarding,
  CcSection.invoices,
  CcSection.payments,
  CcSection.supportHome,
  CcSection.help,
];

const List<CcSection> _ownerToolsOrder = <CcSection>[
  CcSection.packages,
  CcSection.staff,
  CcSection.audit,
  CcSection.settings,
];

List<CcSection> _allowed(StaffProfile profile, List<CcSection> order) =>
    <CcSection>[
      for (final CcSection section in order)
        if (section == CcSection.help || profile.can(section.name)) section,
    ];

CcSection homeSection(StaffProfile profile) {
  for (final CcSection section in CcSection.values) {
    if (section.name == profile.home) return section;
  }
  return CcSection.account;
}

class CcShell extends StatefulWidget {
  const CcShell({
    super.key,
    required this.profile,
    required this.section,
    required this.counts,
    required this.onSelect,
    required this.onSearch,
    required this.onSignOut,
    required this.child,
  });

  final StaffProfile profile;
  final CcSection section;
  final Map<CcSection, int> counts;
  final ValueChanged<CcSection> onSelect;
  final ValueChanged<String> onSearch;
  final VoidCallback onSignOut;
  final Widget child;

  @override
  State<CcShell> createState() => _CcShellState();
}

class _CcShellState extends State<CcShell> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _pick(CcSection section, {bool drawer = false}) {
    if (drawer) Navigator.of(context).pop();
    widget.onSelect(section);
  }

  Widget _navItem(CcSection section, {bool drawer = false}) {
    final bool selected = widget.section == section;
    final int count = widget.counts[section] ?? 0;
    final String label = sectionLabel(section);
    return Semantics(
      button: true,
      selected: selected,
      label: count > 0 ? '$label, $count waiting' : label,
      excludeSemantics: true,
      onTap: () => _pick(section, drawer: drawer),
      child: Material(
        color: selected ? Cc.sidebarActive : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          hoverColor: Cc.sidebarHover,
          onTap: () => _pick(section, drawer: drawer),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                Icon(
                  _icon(section),
                  size: 20,
                  color: selected ? Colors.white : Cc.sidebarMuted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? Colors.white : const Color(0xFFD7E3DC),
                    ),
                  ),
                ),
                if (count > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0B13C),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF3A2500),
                        fontFeatures: Cc.figures,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _group(
    String title,
    List<CcSection> sections, {
    bool drawer = false,
  }) => sections.isEmpty
      ? const SizedBox.shrink()
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 18, 12, 8),
              child: Text(
                title.toUpperCase(),
                style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700,
                  color: Cc.sidebarMuted,
                ),
              ),
            ),
            for (final CcSection section in sections)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: _navItem(section, drawer: drawer),
              ),
          ],
        );

  Widget _sidebar({bool drawer = false}) => Container(
    color: Cc.sidebar,
    padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
    child: SafeArea(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 40,
                    height: 40,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Image.asset(
                      'assets/images/ScootSales-icon.png',
                      fit: BoxFit.contain,
                      semanticLabel: 'Scoot Sales',
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Scoot Sales',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        'Control Centre',
                        style: TextStyle(color: Cc.sidebarMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _group(
              'Work',
              _allowed(widget.profile, _workOrder),
              drawer: drawer,
            ),
            _group(
              'Owner tools',
              _allowed(widget.profile, _ownerToolsOrder),
              drawer: drawer,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _accountChip() {
    final String name = widget.profile.email.split('@').first;
    final String initial = name.isEmpty ? '?' : name[0].toUpperCase();
    return PopupMenuButton<String>(
      tooltip: 'Account menu',
      offset: const Offset(0, 48),
      onSelected: (String value) {
        if (value == 'account') widget.onSelect(CcSection.account);
        if (value == 'signout') widget.onSignOut();
      },
      itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'account',
          height: 44,
          child: Text('My account'),
        ),
        PopupMenuItem<String>(
          value: 'signout',
          height: 44,
          child: Text('Sign out'),
        ),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Cc.line),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircleAvatar(
              radius: 16,
              backgroundColor: Cc.accent,
              child: Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  widget.profile.email,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Cc.ink,
                  ),
                ),
                Text(roleLabel(widget.profile.role), style: Cc.small),
              ],
            ),
            const Icon(Icons.expand_more, size: 18, color: Cc.muted),
          ],
        ),
      ),
    );
  }

  Widget _header(bool narrow) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: Cc.line)),
    ),
    child: Row(
      children: <Widget>[
        if (narrow)
          IconButton(
            tooltip: 'Open navigation',
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            onPressed: () => _scaffold.currentState?.openDrawer(),
            icon: const Icon(Icons.menu),
          ),
        if (widget.profile.seesCommercialData)
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: TextField(
                  controller: _search,
                  focusNode: _searchFocus,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText:
                        'Company, workspace code, billing email or invoice no.',
                    prefixIcon: const Icon(Icons.search),
                    suffixText: narrow ? null : 'Ctrl K',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                  ),
                  onSubmitted: (String value) {
                    widget.onSearch(value.trim());
                    _search.clear();
                  },
                ),
              ),
            ),
          )
        else
          const Spacer(),
        const SizedBox(width: 12),
        Semantics(container: true, child: _accountChip()),
      ],
    ),
  );

  KeyEventResult _handleShellKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent ||
        event.logicalKey != LogicalKeyboardKey.keyK ||
        !HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    _searchFocus.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final bool narrow = MediaQuery.sizeOf(context).width < 900;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onKeyEvent: _handleShellKey,
      child: Scaffold(
        key: _scaffold,
        backgroundColor: Cc.canvas,
        drawer: narrow ? Drawer(child: _sidebar(drawer: true)) : null,
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (!narrow) SizedBox(width: 236, child: _sidebar()),
            Expanded(
              child: Column(
                children: <Widget>[
                  _header(narrow),
                  Expanded(child: widget.child),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CcPage extends StatelessWidget {
  const CcPage({super.key, required this.child, this.maxWidth = 1600});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) =>
        SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            constraints.maxWidth < 600 ? 16 : 28,
            24,
            constraints.maxWidth < 600 ? 16 : 28,
            48,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: child,
            ),
          ),
        ),
  );
}
