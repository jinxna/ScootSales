import 'package:flutter/material.dart';

import '../common/badges.dart';
import '../common/pressable.dart';
import '../tokens/colors.dart';
import '../tokens/icons.dart';
import '../tokens/metrics.dart';

class ScootNavItem {
  const ScootNavItem({
    required this.id,
    required this.label,
    required this.icon,
    this.count,
    this.countLabel,
    this.countText,
  });

  final String id;
  final String label;
  final IconData icon;
  final int? count;
  final String? countLabel;
  final String? countText;
}

class ScootNavGroup {
  const ScootNavGroup({
    this.label,
    required this.items,
    this.collapsible = false,
  });

  final String? label;
  final List<ScootNavItem> items;
  final bool collapsible;

  bool contains(String? id) =>
      id != null && items.any((ScootNavItem item) => item.id == id);
}

class ScootRailLink {
  const ScootRailLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;
}

class ScootRail extends StatefulWidget {
  const ScootRail({
    super.key,
    required this.groups,
    required this.selectedId,
    required this.onSelect,
    this.productName = 'Scoot Sales',
    this.companyName,
    this.footerLinks = const <ScootRailLink>[],
  });

  final List<ScootNavGroup> groups;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final String productName;
  final String? companyName;
  final List<ScootRailLink> footerLinks;

  @override
  State<ScootRail> createState() => _ScootRailState();
}

class _ScootRailState extends State<ScootRail> {
  final Set<int> _opened = <int>{};
  final Set<int> _closed = <int>{};

  bool _isOpen(int index) {
    final ScootNavGroup group = widget.groups[index];
    if (!group.collapsible) return true;
    if (_closed.contains(index)) return false;
    return _opened.contains(index) || group.contains(widget.selectedId);
  }

  @override
  void didUpdateWidget(ScootRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedId != widget.selectedId) {
      for (int i = 0; i < widget.groups.length; i++) {
        if (widget.groups[i].contains(widget.selectedId)) _closed.remove(i);
      }
    }
  }

  void _toggle(int index) {
    setState(() {
      if (_isOpen(index)) {
        _opened.remove(index);
        _closed.add(index);
      } else {
        _closed.remove(index);
        _opened.add(index);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Main menu',
      child: Container(
        width: ScootSize.rail,
        color: c.navBg,
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Brand(name: widget.productName, company: widget.companyName),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: <Widget>[
                  for (int i = 0; i < widget.groups.length; i++)
                    ..._group(context, i),
                ],
              ),
            ),
            if (widget.footerLinks.isNotEmpty)
              _Footer(links: widget.footerLinks),
          ],
        ),
      ),
    );
  }

  List<Widget> _group(BuildContext context, int index) {
    final ScootNavGroup group = widget.groups[index];
    final bool open = _isOpen(index);
    return <Widget>[
      if (group.label != null && !group.collapsible)
        _GroupLabel(label: group.label!),
      if (group.label != null && group.collapsible)
        _GroupToggle(
          label: group.label!,
          itemCount: group.items.length,
          open: open,
          onTap: () => _toggle(index),
        ),
      if (open)
        for (final ScootNavItem item in group.items)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: ScootNavTile(
              item: item,
              selected: item.id == widget.selectedId,
              onTap: () => widget.onSelect(item.id),
            ),
          ),
    ];
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.name, required this.company});

  final String name;
  final String? company;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFFFFFFFF),
              borderRadius: ScootRadius.controlAll,
            ),
            child: Text(
              name.isEmpty ? 'S' : name.characters.first,
              style: ScootType.h2.copyWith(
                color: ScootPalette.brand,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ScootType.section.copyWith(
                    color: const Color(0xFFFFFFFF),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (company != null)
                  Text(
                    company!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ScootType.caption.copyWith(color: c.navLabel),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 6),
        child: Text(
          label.toUpperCase(),
          style: ScootType.navLabel.copyWith(
            color: ScootColors.of(context).navLabel,
          ),
        ),
      ),
    );
  }
}

class _GroupToggle extends StatelessWidget {
  const _GroupToggle({
    required this.label,
    required this.itemCount,
    required this.open,
    required this.onTap,
  });

  final String label;
  final int itemCount;
  final bool open;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: ScootPressable(
        onTap: onTap,
        minSize: const Size(double.infinity, ScootSize.dashboardTarget),
        hoverColor: c.navHover,
        focusRingColor: c.navText,
        semanticLabel:
            '$label, $itemCount pages, ${open ? 'expanded' : 'collapsed'}',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: <Widget>[
              Text(
                label.toUpperCase(),
                style: ScootType.navLabel.copyWith(color: c.navLabel),
              ),
              const Spacer(),
              if (!open)
                Text(
                  '$itemCount',
                  style: ScootType.caption.copyWith(
                    color: c.navLabel,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(width: 6),
              Icon(
                open ? ScootIcons.expandLess : ScootIcons.expandMore,
                size: 18,
                color: c.navLabel,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ScootNavTile extends StatelessWidget {
  const ScootNavTile({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final ScootNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final Color fg = selected ? const Color(0xFFFFFFFF) : c.navText;
    final String countText = item.count == null || item.count == 0
        ? ''
        : ', ${item.countLabel ?? '${item.count} waiting'}';
    return ScootPressable(
      onTap: onTap,
      selected: selected,
      minSize: const Size(double.infinity, ScootSize.dashboardTarget),
      color: selected ? c.navOn : null,
      hoverColor: c.navHover,
      focusRingColor: c.navText,
      semanticLabel:
          '${item.label}$countText${selected ? ', current page' : ''}',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: <Widget>[
            Icon(item.icon, size: ScootSize.icon, color: fg),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ScootType.body.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (item.count != null && item.count! > 0)
              ScootCountBadge(
                count: item.count!,
                text: item.countText,
                semanticLabel: item.countLabel ?? '${item.count} waiting',
              ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.links});

  final List<ScootRailLink> links;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.navDivider)),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          for (int i = 0; i < links.length; i++) ...<Widget>[
            if (i > 0)
              ExcludeSemantics(
                child: Text(
                  '·',
                  style: ScootType.caption.copyWith(color: c.navLabel),
                ),
              ),
            ScootPressable(
              onTap: links[i].onTap,
              minSize: const Size(0, ScootSize.dashboardTarget),
              hoverColor: c.navHover,
              focusRingColor: c.navText,
              semanticLabel: links[i].label,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    links[i].label,
                    style: ScootType.caption.copyWith(color: c.navText),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
