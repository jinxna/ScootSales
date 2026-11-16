import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../app/permission_policy.dart';
import '../../../models/user_profile.dart';
import '../../../services/auth_service.dart';
import '../../../services/permission_policy_service.dart';
import '../widgets/cms_panel.dart';

class PermissionMatrixPage extends StatefulWidget {
  const PermissionMatrixPage({super.key, required this.currentUser});

  final UserProfile currentUser;

  @override
  State<PermissionMatrixPage> createState() => _PermissionMatrixPageState();
}

class _PermissionMatrixPageState extends State<PermissionMatrixPage> {
  PermissionPolicyService get _service => PermissionPolicyService.instance;

  PermissionPolicy? _draft;
  String _role = PermissionModuleRegistry.roleBranchManager;
  bool _saving = false;

  static const String _readDeniedNote =
      'The live database has not been updated to store this permission table '
      'yet. Built-in defaults are shown and in effect.';

  static const Map<String, String> _roleLabels = <String, String>{
    'admin': 'Admin',
    'branch_manager': 'Branch Manager',
    'supervisor': 'Supervisor',
  };

  @override
  void initState() {
    super.initState();
    _service.startSession();
    _service.policy.addListener(_onPolicyChanged);
    if (!_service.loadedFromDocument) {
      _service.load().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _service.policy.removeListener(_onPolicyChanged);
    super.dispose();
  }

  void _onPolicyChanged() {
    if (mounted) setState(() => _draft = null);
  }

  void _toggle(String moduleId, PermissionAction action, bool allowed) {
    setState(() {
      PermissionPolicy next = (_draft ?? _service.policy.value).withCell(
        _role,
        moduleId,
        action,
        allowed: allowed,
      );
      if (action == PermissionAction.view &&
          !allowed &&
          PermissionModuleRegistry.isDelegated(_role, moduleId)) {
        for (final PermissionAction write
            in PermissionModuleRegistry.writeActions) {
          next = next.withCell(_role, moduleId, write, allowed: false);
        }
      }
      _draft = next;
    });
  }

  Future<void> _save() async {
    final PermissionPolicy? draft = _draft;
    if (draft == null || _saving) return;
    final List<String> adminViewLosses = <String>[
      for (final PermissionModule module in PermissionModuleRegistry.modules)
        if (_service.policy.value.allows(
              PermissionModuleRegistry.roleAdmin,
              module.id,
              PermissionAction.view,
            ) &&
            !draft.allows(
              PermissionModuleRegistry.roleAdmin,
              module.id,
              PermissionAction.view,
            ))
          module.label,
    ];
    if (adminViewLosses.isNotEmpty && !await _confirm(adminViewLosses)) return;
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      await _service.save(next: draft, actor: widget.currentUser);
      _message('Permissions saved and recorded in the audit log.');
    } catch (error) {
      _message(
        AuthService.instance.describeUserManagementError(error),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirm(List<String> modules) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Remove Admin view access?'),
        content: Text(
          'Saving removes Admin view access to: ${modules.join(', ')}.\n\n'
          'This editor stays available to Admin so the change can be reverted, '
          'but the affected pages will stop loading their data until it is.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Save anyway'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  void _message(String message, {bool isError = false}) {
    if (!mounted) return;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? scheme.errorContainer : null,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PermissionPolicy>(
      valueListenable: _service.policy,
      builder: (BuildContext context, PermissionPolicy stored, Widget? _) {
        final PermissionPolicy shown = _draft ?? stored;
        final int changes = shown.diffAgainst(stored).length;
        final ColorScheme scheme = Theme.of(context).colorScheme;
        return CmsPanel(
          title: 'Permission matrix',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (changes > 0) ...<Widget>[
                Text(
                  '$changes unsaved change${changes == 1 ? '' : 's'}',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() => _draft = null),
                  child: const Text('Discard'),
                ),
              ],
              Tooltip(
                message: _service.readDenied ? _readDeniedNote : '',
                child: FilledButton.icon(
                  onPressed: changes == 0 || _saving || _service.readDenied
                      ? null
                      : _save,
                  icon: const Icon(ScootIcons.check, size: 18),
                  label: Text(_saving ? 'Saving' : 'Save changes'),
                ),
              ),
            ],
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            children: <Widget>[
              if (MediaQuery.sizeOf(context).width < 600)
                DropdownButtonFormField<String>(
                  initialValue: _role,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Role',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: <DropdownMenuItem<String>>[
                    for (final String role
                        in PermissionModuleRegistry.matrixRoles)
                      DropdownMenuItem<String>(
                        value: role,
                        child: Text(_roleLabels[role] ?? role),
                      ),
                  ],
                  onChanged: (String? role) {
                    if (role != null) setState(() => _role = role);
                  },
                )
              else
                SegmentedButton<String>(
                  segments: <ButtonSegment<String>>[
                    for (final String role
                        in PermissionModuleRegistry.matrixRoles)
                      ButtonSegment<String>(
                        value: role,
                        label: Text(_roleLabels[role] ?? role),
                      ),
                  ],
                  selected: <String>{_role},
                  onSelectionChanged: (Set<String> selection) =>
                      setState(() => _role = selection.first),
                ),
              const SizedBox(height: 12),
              Text(
                'A tick is enforced by the system as well as this '
                'dashboard, and takes effect at once for everyone signed in. '
                'Supervisors and Branch Managers can be given Create, Edit and '
                'Delete on every module. Products, Departments, Categories and '
                'Website Content apply to the whole company. Retailer Score '
                'Sheets and Retailer Department PIC apply to shops of their own '
                'team only. Edit on Products and Score Sheets includes prices. '
                'A write tick needs View. With no tick they keep View only. '
                'Developer stays root authority. Roles, '
                'branch/team scope, approvals and system settings are not '
                'modules and cannot be changed here. Revoking View hides a '
                'module from dashboard roles only; the salesman app is '
                'unaffected. '
                '${_service.loadedFromDocument ? 'Stored table, revision ${stored.revision}.' : 'No stored table yet: showing the built-in defaults.'}',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (_service.readDenied) ...<Widget>[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      ScootIcons.info,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _readDeniedNote,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ] else if (_service.lastError.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  'Last read error: ${_service.lastError}',
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ],
              const SizedBox(height: 14),
              _tableShell(
                scheme,
                <Widget>[
                  _headerRow(scheme),
                  for (final PermissionModule module
                      in PermissionModuleRegistry.modules)
                    _moduleRow(module, shown, scheme),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  String? _reasonFor(PermissionModule module) {
    if (_role == PermissionModuleRegistry.roleAdmin) return null;
    final String scope =
        PermissionModuleRegistry.teamScopedModuleIds.contains(module.id)
        ? 'Create, Edit and Delete apply to shops of their own team only'
        : 'Create, Edit and Delete apply to the whole company';
    final String prices =
        PermissionModuleRegistry.priceModuleIds.contains(module.id)
        ? ' Edit includes prices.'
        : '';
    final String library = module.id == 'retailer_scoresheets'
        ? ', never the company default sheet.'
        : '.';
    return '$scope$library$prices';
  }

  Widget _tableShell(ColorScheme scheme, List<Widget> rows) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(color: c.line),
        borderRadius: ScootRadius.noteAll,
      ),
      child: Column(children: rows),
    );
  }

  Widget _headerRow(ColorScheme scheme) {
    final ScootColors c = ScootColors.of(context);
    final bool compact = MediaQuery.sizeOf(context).width < 600;
    final TextStyle style = ScootType.tableHead.copyWith(
      color: c.tableHeadText,
    );
    return Container(
      height: ScootSize.tableHeader,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: c.tableHead,
      child: Row(
        children: <Widget>[
          Expanded(child: Text('Module', style: style)),
          if (!compact)
            for (final PermissionAction action in PermissionAction.values)
              SizedBox(
                width: 74,
                child: Center(child: Text(action.label, style: style)),
              ),
        ],
      ),
    );
  }

  Widget _moduleRow(
    PermissionModule module,
    PermissionPolicy shown,
    ColorScheme scheme,
  ) {
    final bool compact = MediaQuery.sizeOf(context).width < 600;

    Widget checkbox(PermissionAction action) => Checkbox(
      key: ValueKey<String>('cell-$_role-${module.id}-${action.wire}'),
      semanticLabel: '${module.label} ${action.label}',
      value: shown.allows(_role, module.id, action),
      onChanged:
          PermissionModuleRegistry.isCellConfigurable(_role, module.id, action) &&
              (action == PermissionAction.view ||
                  !PermissionModuleRegistry.isDelegated(_role, module.id) ||
                  shown.allows(_role, module.id, PermissionAction.view))
          ? (bool? value) {
              if (value != null) _toggle(module.id, action, value);
            }
          : null,
    );

    final String? reason = _reasonFor(module);
    final Widget? reasonText = reason == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              reason,
              key: ValueKey<String>('reason-$_role-${module.id}'),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          );

    final ScootColors c = ScootColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        color: c.card,
        border: Border(top: BorderSide(color: c.hair)),
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  module.label,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                ?reasonText,
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  children: <Widget>[
                    for (final PermissionAction action
                        in PermissionAction.values)
                      SizedBox(
                        width: 90,
                        child: MergeSemantics(
                          child: Row(
                            children: <Widget>[
                              checkbox(action),
                              const SizedBox(width: 2),
                              Expanded(
                                child: Text(
                                  action.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            )
          : Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        module.label,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      ?reasonText,
                    ],
                  ),
                ),
                for (final PermissionAction action in PermissionAction.values)
                  SizedBox(
                    width: 74,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[checkbox(action)],
                    ),
                  ),
              ],
            ),
    );
  }
}
