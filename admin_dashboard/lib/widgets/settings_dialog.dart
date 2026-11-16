import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../theme/dso_theme.dart';
import '../theme/theme_controller.dart';
import 'avatar_storage.dart';
import 'user_avatar.dart';

class DsoSettingsProfile {
  const DsoSettingsProfile({
    required this.authUid,
    required this.userDocId,
    required this.name,
    required this.email,
    required this.role,
    required this.branch,
    required this.userCode,
    required this.status,
  });

  final String userDocId;
  final String authUid;
  final String name;
  final String email;
  final String role;
  final String branch;
  final String userCode;
  final String status;
}

Future<void> showDsoSettings(
  BuildContext context, {
  required DsoSettingsProfile profile,
  int initialTab = 0,
}) {
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  return showDialog<void>(
    context: context,
    barrierColor: dark ? const Color(0xAA000000) : const Color(0x73120F0E),
    builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      insetPadding: EdgeInsets.all(
        MediaQuery.sizeOf(context).width < _narrowDialogWidth ? 12 : 28,
      ),
      child: _SettingsBody(profile: profile, initialTab: initialTab),
    ),
  );
}

class _SettingsBody extends StatefulWidget {
  const _SettingsBody({required this.profile, this.initialTab = 0});

  final DsoSettingsProfile profile;
  final int initialTab;

  @override
  State<_SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<_SettingsBody> {
  late int _tab;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab.clamp(0, _nav.length - 1);
  }

  static const List<_SettingsNavItem> _nav = <_SettingsNavItem>[
    _SettingsNavItem(Icons.person_outline, 'Profile'),
    _SettingsNavItem(Icons.palette_outlined, 'Appearance'),
  ];

  Widget _header(ColorScheme scheme, {required double left}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(left, 16, 16, 16),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              _nav[_tab].label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 19),
            color: scheme.onSurfaceVariant,
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }

  Widget _narrowLayout(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _header(scheme, left: 16),
        Container(
          color: scheme.surfaceContainerHighest,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
          child: Row(
            children: <Widget>[
              for (int i = 0; i < _nav.length; i++)
                Expanded(
                  child: _NavRow(
                    icon: _nav[i].icon,
                    label: _nav[i].label,
                    selected: _tab == i,
                    onTap: () => setState(() => _tab = i),
                  ),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: scheme.outlineVariant),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _PaneFor(tab: _tab, profile: widget.profile),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 640),
        child: Material(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(DsoTokens.rDialog),
          clipBehavior: Clip.antiAlias,
          child: SelectionArea(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) =>
                  constraints.maxWidth < _narrowDialogWidth
                  ? _narrowLayout(scheme)
                  : _wideLayout(scheme),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wideLayout(ColorScheme scheme) {
    return Row(
      children: <Widget>[
        Container(
          width: 220,
          color: scheme.surfaceContainerHighest,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 12),
                child: Text(
                  'Settings',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              for (int i = 0; i < _nav.length; i++)
                _NavRow(
                  icon: _nav[i].icon,
                  label: _nav[i].label,
                  selected: _tab == i,
                  onTap: () => setState(() => _tab = i),
                ),
            ],
          ),
        ),
        VerticalDivider(width: 1, color: scheme.outlineVariant),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _header(scheme, left: 22),
              Divider(height: 1, color: scheme.outlineVariant),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(22),
                  child: _PaneFor(tab: _tab, profile: widget.profile),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

const double _narrowDialogWidth = 560;

class _SettingsNavItem {
  const _SettingsNavItem(this.icon, this.label);

  final IconData icon;
  final String label;
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? scheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          boxShadow: selected
              ? const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x0F1C1917),
                    blurRadius: 2,
                    offset: Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: <Widget>[
            Icon(
              icon,
              size: 19,
              color: selected ? DsoTokens.green600 : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? DsoTokens.green600 : scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaneFor extends StatelessWidget {
  const _PaneFor({required this.tab, required this.profile});

  final int tab;
  final DsoSettingsProfile profile;

  @override
  Widget build(BuildContext context) {
    return switch (tab) {
      1 => const _AppearancePane(),
      _ => _ProfilePane(profile: profile),
    };
  }
}

class _ProfilePane extends StatefulWidget {
  const _ProfilePane({required this.profile});

  final DsoSettingsProfile profile;

  @override
  State<_ProfilePane> createState() => _ProfilePaneState();
}

class _ProfilePaneState extends State<_ProfilePane> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.profile.name,
  );
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _canSave {
    final String next = _nameController.text.trim();
    return !_saving &&
        next.isNotEmpty &&
        next != widget.profile.name.trim() &&
        widget.profile.userDocId.isNotEmpty;
  }

  Future<void> _save() async {
    final String newName = _nameController.text.trim();
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.profile.userDocId)
          .update(<String, dynamic>{'name': newName});
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile updated.')));
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not update profile. Please try again.'),
        ),
      );
    }
  }

  Future<void> _choosePhoto() async {
    try {
      final bool saved = await UserAvatarStorage.chooseAndSave(
        widget.profile.authUid,
      );
      if (!mounted || !saved) return;
      setState(() {});
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not use that image. Choose a smaller image and try again.',
          ),
        ),
      );
    }
  }

  void _clearPhoto() {
    UserAvatarStorage.clear(widget.profile.authUid);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final DsoSettingsProfile profile = widget.profile;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            DsoUserAvatar(
              initial: _initial(profile.name),
              size: 56,
              uid: profile.authUid,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    profile.name.isEmpty ? 'Current user' : profile.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    profile.email.isEmpty ? 'Email not set' : profile.email,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: profile.authUid.isEmpty || _saving
                  ? null
                  : _choosePhoto,
              icon: const Icon(Icons.photo_outlined, size: 18),
              label: const Text('Choose photo'),
            ),
            TextButton.icon(
              onPressed: profile.authUid.isEmpty || _saving
                  ? null
                  : _clearPhoto,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Remove photo'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Your photo is resized and stored only in this browser for this account. '
          'It does not sync or appear to other staff. Clearing this browser’s site data removes it. '
          'Initials are shown if no photo is available.',
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        _editableField(
          context,
          'Full name',
          controller: _nameController,
          enabled: profile.userDocId.isNotEmpty && !_saving,
          onChanged: () => setState(() {}),
        ),
        _readonlyField(
          context,
          'Email',
          profile.email.isEmpty ? 'Not set' : profile.email,
        ),
        _readonlyField(
          context,
          'Staff ID',
          profile.userCode.isEmpty ? 'Not set' : profile.userCode,
        ),
        _readonlyPill(
          context,
          'Role',
          _humanize(profile.role, fallback: 'Not set'),
        ),
        _readonlyField(
          context,
          'Branch',
          _humanize(profile.branch, fallback: 'Not linked'),
        ),
        _readonlyPill(
          context,
          'Status',
          _humanize(profile.status, fallback: 'Unknown'),
        ),
        const SizedBox(height: 6),
        Text(
          profile.userDocId.isEmpty
              ? 'Sign in with a connected account to edit your display name. '
                    'Role, branch and status are managed in User Management.'
              : 'Only your display name can be changed here. Role, branch and '
                    'status are managed in User Management.',
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _canSave ? _save : null,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: DsoTokens.white,
                      ),
                    )
                  : const Text('Save changes'),
            ),
          ],
        ),
      ],
    );
  }

  static String _humanize(String value, {required String fallback}) {
    final String text = value.trim();
    if (text.isEmpty) return fallback;
    return text
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .split(RegExp(r'\s+'))
        .map(
          (String word) => word.isEmpty
              ? word
              : '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}',
        )
        .join(' ');
  }

  static Widget _editableField(
    BuildContext context,
    String label, {
    required TextEditingController controller,
    required bool enabled,
    required VoidCallback onChanged,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              onChanged: (_) => onChanged(),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _readonlyField(
    BuildContext context,
    String label,
    String value,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(DsoTokens.rMd),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 13.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _readonlyPill(
    BuildContext context,
    String label,
    String value,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: context.dso.brandSurface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  value,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: DsoTokens.green700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppearancePane extends StatelessWidget {
  const _AppearancePane();

  static const List<Color> _accents = <Color>[
    DsoTokens.green550,
    DsoTokens.green600,
    DsoTokens.info,
    DsoTokens.warningAmber,
    DsoTokens.danger,
  ];

  @override
  Widget build(BuildContext context) {
    final DsoThemeController controller = DsoThemeController.instance;
    return ValueListenableBuilder<DsoAppearance>(
      valueListenable: controller,
      builder: (BuildContext context, DsoAppearance appearance, Widget? _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const _AppearanceLabel('Theme'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                _ThemeChoice(
                  label: 'Light',
                  color: DsoTokens.white,
                  selected: appearance.mode == DsoThemeMode.light,
                  onTap: () => controller.setMode(DsoThemeMode.light),
                ),
                _ThemeChoice(
                  label: 'Dark',
                  color: const Color(0xFF111715),
                  selected: appearance.mode == DsoThemeMode.dark,
                  onTap: () => controller.setMode(DsoThemeMode.dark),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const _AppearanceLabel('Accent'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                for (final Color accent in _accents)
                  _Swatch(
                    color: accent,
                    selected: appearance.accent == accent,
                    onTap: () => controller.setAccent(accent),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            const _AppearanceLabel('Density'),
            const SizedBox(height: 10),
            SegmentedButton<DsoDensity>(
              segments: const <ButtonSegment<DsoDensity>>[
                ButtonSegment<DsoDensity>(
                  value: DsoDensity.compact,
                  label: Text('Compact'),
                ),
                ButtonSegment<DsoDensity>(
                  value: DsoDensity.comfortable,
                  label: Text('Comfortable'),
                ),
                ButtonSegment<DsoDensity>(
                  value: DsoDensity.spacious,
                  label: Text('Spacious'),
                ),
              ],
              selected: <DsoDensity>{appearance.density},
              onSelectionChanged: (Set<DsoDensity> value) =>
                  controller.setDensity(value.first),
            ),
            const SizedBox(height: 16),
            Text(
              'Applies instantly. Saved in this browser for your account.',
              style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AppearanceLabel extends StatelessWidget {
  const _AppearanceLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
    );
  }
}

class _ThemeChoice extends StatelessWidget {
  const _ThemeChoice({
    required this.label,
    required this.color,
    required this.onTap,
    this.selected = false,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 126,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? DsoTokens.green500 : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              height: 54,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.outlineVariant),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: selected
                          ? context.dso.accentText
                          : scheme.onSurface,
                    ),
                  ),
                ),
                if (selected)
                  Icon(
                    Icons.check_circle,
                    size: 16,
                    color: context.dso.accentText,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.onTap,
    this.selected = false,
  });

  final Color color;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 32,
        height: 32,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.onSurface : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

String _initial(String value) {
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return '?';
  return trimmed.characters.first.toUpperCase();
}
