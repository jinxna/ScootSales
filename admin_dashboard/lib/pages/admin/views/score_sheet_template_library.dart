import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../services/score_sheet_template_service.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/user_facing_error.dart';
import '../../../widgets/catalogue/catalogue_states.dart';

class ScoreSheetTemplateLibrary extends StatefulWidget {
  const ScoreSheetTemplateLibrary({
    super.key,
    required this.retailers,
    required this.currentProductIds,
    required this.currentRetailerId,
    required this.currentRetailerName,
  });

  final List<Map<String, dynamic>> retailers;
  final List<String>? currentProductIds;
  final String currentRetailerId;
  final String currentRetailerName;

  @override
  State<ScoreSheetTemplateLibrary> createState() =>
      _ScoreSheetTemplateLibraryState();
}

class _ScoreSheetTemplateLibraryState extends State<ScoreSheetTemplateLibrary> {
  final ScoreSheetTemplateService _service = ScoreSheetTemplateService();
  late final Stream<ScoreSheetLibrarySnapshot> _library = _service
      .watchLibrary();
  late final Stream<List<Map<String, dynamic>>> _users = CmsRepository()
      .watchCollection('users', orderBy: 'name');
  Future<String?> _attempt(String action, Future<void> Function() write) async {
    try {
      await write();
      return null;
    } on StateError catch (error) {
      return error.message;
    } catch (error) {
      return userFacingError(error, action: action);
    }
  }

  Future<void> _saveCurrentSheet(ScoreSheetLibrarySnapshot library) async {
    final List<String>? productIds = widget.currentProductIds;
    if (productIds == null) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => _TemplateNameDialog(
        title: 'Save current sheet as template',
        confirmLabel: 'Create template',
        existingNames: _names(library),
        onSave: (String name) => _attempt(
          'save the template',
          () => _service.createTemplate(
            name: name,
            productIds: productIds,
            sourceRetailerId: widget.currentRetailerId,
            sourceRetailerName: widget.currentRetailerName,
          ),
        ),
      ),
    );
  }

  Future<void> _copy(
    ScoreSheetLibrarySnapshot library,
    ScoreSheetTemplate template,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => _TemplateNameDialog(
        title: 'Copy ${template.name}',
        confirmLabel: 'Create copy',
        existingNames: _names(library),
        onSave: (String name) => _attempt(
          'copy the template',
          () => _service.createTemplate(
            name: name,
            productIds: template.productIds,
            copiedFrom: template,
          ),
        ),
      ),
    );
  }

  Future<void> _newVersion(ScoreSheetTemplate template) async {
    final List<String>? productIds = widget.currentProductIds;
    if (productIds == null || productIds.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => _NewVersionDialog(
        template: template,
        productCount: productIds.length,
        retailerName: widget.currentRetailerName,
        onSave: () => _attempt(
          'save the new template version',
          () => _service.createNextRevision(
            template: template,
            productIds: productIds,
            sourceRetailerId: widget.currentRetailerId,
            sourceRetailerName: widget.currentRetailerName,
          ),
        ),
      ),
    );
  }

  Future<void> _assign(
    ScoreSheetLibrarySnapshot library,
    ScoreSheetTemplate template,
    List<ScoreSheetSalesperson> salespeople,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => _AssignDialog(
        templateName: template.name,
        salespeople: salespeople,
        retailers: _retailerOptions(),
        current: library.currentAssignmentsFor(template.templateId),
        onSave: (_AssignmentChoice choice) => _attempt(
          'save the assignment',
          () => _service.assign(
            template: template,
            salesperson: choice.salesperson,
            retailerId: choice.retailerId,
            retailerName: choice.retailerName,
          ),
        ),
      ),
    );
  }

  Future<void> _reassign(
    ScoreSheetLibrarySnapshot library,
    ScoreSheetTemplate template,
    List<ScoreSheetSalesperson> salespeople,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => _ReassignDialog(
        templateName: template.name,
        salespeople: salespeople,
        current: library.currentAssignmentsFor(template.templateId),
        onSave: (_ReassignmentChoice choice) => _attempt(
          'save the reassignment',
          () => _service.reassign(
            current: choice.current,
            salesperson: choice.salesperson,
          ),
        ),
      ),
    );
  }

  Future<void> _retire(ScoreSheetTemplate template) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => _RetireDialog(
        templateName: template.name,
        onSave: () => _attempt(
          'retire the template',
          () => _service.retireTemplate(template),
        ),
      ),
    );
  }

  Set<String> _names(ScoreSheetLibrarySnapshot library) => library.templates
      .map((ScoreSheetTemplate t) => t.name.trim().toLowerCase())
      .toSet();

  List<_RetailerOption> _retailerOptions() {
    final List<_RetailerOption> options = <_RetailerOption>[];
    for (final Map<String, dynamic> retailer in widget.retailers) {
      final String id = _firstText(retailer, const <String>[
        'retailerId',
        'docId',
      ]);
      if (id.isEmpty) continue;
      final String name = _firstText(retailer, const <String>[
        'retailerName',
        'name',
      ]);
      options.add(_RetailerOption(id, name.isEmpty ? id : name));
    }
    return options;
  }

  List<ScoreSheetSalesperson> _salespeople(List<Map<String, dynamic>> users) {
    final List<ScoreSheetSalesperson> people = <ScoreSheetSalesperson>[];
    final Set<String> seen = <String>{};
    for (final Map<String, dynamic> user in users) {
      final String role = UserProfile.normalizeRole(
        user['role'] ?? user['user_group'],
        email: user['email'],
      );
      final String status = UserProfile.normalizeStatus(
        user['status'],
        isActive: user['isActive'],
      );
      if (role != UserProfile.roleSalesman ||
          status != UserProfile.statusActive) {
        continue;
      }
      final String uid = _firstText(user, const <String>['uid', 'userUid']);
      if (uid.isEmpty || !seen.add(uid)) continue;
      final String name = _firstText(user, const <String>[
        'name',
        'displayName',
      ]);
      people.add(
        ScoreSheetSalesperson(
          uid: uid,
          name: name.isEmpty ? uid : name,
          code: _firstText(user, const <String>['employeeCode', 'userId']),
        ),
      );
    }
    people.sort(
      (ScoreSheetSalesperson a, ScoreSheetSalesperson b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return people;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _users,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> usersSnapshot,
          ) => StreamBuilder<ScoreSheetLibrarySnapshot>(
            stream: _library,
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<ScoreSheetLibrarySnapshot> librarySnapshot,
                ) {
                  if (librarySnapshot.hasError) {
                    return CatalogueError(
                      message: userFacingError(
                        librarySnapshot.error!,
                        action: 'load the template library',
                      ),
                    );
                  }
                  final ScoreSheetLibrarySnapshot? library =
                      librarySnapshot.data;
                  if (library == null) return const CatalogueLoading();
                  return _buildLibrary(
                    context,
                    library,
                    _salespeople(
                      usersSnapshot.data ?? const <Map<String, dynamic>>[],
                    ),
                  );
                },
          ),
    );
  }

  Widget _buildLibrary(
    BuildContext context,
    ScoreSheetLibrarySnapshot library,
    List<ScoreSheetSalesperson> salespeople,
  ) {
    final List<String>? productIds = widget.currentProductIds;
    final Widget templates = _panel(
      context,
      'Templates',
      library.templates.isEmpty
          ? const CatalogueEmpty(
              title: 'No templates yet',
              message:
                  'Save a retailer sheet as a template to reuse its product list.',
            )
          : ListView.separated(
              itemCount: library.templates.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (BuildContext context, int index) => _templateCard(
                context,
                library,
                library.templates[index],
                salespeople,
              ),
            ),
    );
    final Widget history = _historyPanel(context, library);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            FilledButton.icon(
              onPressed: productIds == null || productIds.isEmpty
                  ? null
                  : () => _saveCurrentSheet(library),
              icon: const Icon(ScootIcons.add, size: 18),
              label: const Text('Save current sheet as template'),
            ),
            Text(
              productIds == null
                  ? 'Choose a retailer to save its sheet as a template.'
                  : productIds.isEmpty
                  ? 'This sheet shows no products on mobile, so it cannot be a template.'
                  : 'Saves the ${productIds.length} products visible on mobile '
                        'for ${widget.currentRetailerName}, including unsaved '
                        'changes. Templates hold products only; prices still '
                        'come from the master catalogue and retailer settings.',
              style: ScootType.body.copyWith(color: context.dso.muted),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              if (box.maxWidth >= 900) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(child: templates),
                    const SizedBox(width: 16),
                    SizedBox(width: 420, child: history),
                  ],
                );
              }
              return Column(
                children: <Widget>[
                  Expanded(flex: 3, child: templates),
                  const SizedBox(height: 12),
                  Expanded(flex: 2, child: history),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _templateCard(
    BuildContext context,
    ScoreSheetLibrarySnapshot library,
    ScoreSheetTemplate template,
    List<ScoreSheetSalesperson> salespeople,
  ) {
    final List<ScoreSheetAssignmentEvent> current = library
        .currentAssignmentsFor(template.templateId);
    final List<String> details = <String>[
      'Version ${template.revision}',
      '${template.productIds.length} products',
      if (template.sourceRetailerName.isNotEmpty)
        'from ${template.sourceRetailerName}',
      if (template.copiedFromName.isNotEmpty)
        'copied from ${template.copiedFromName} v${template.copiedFromRevision ?? 1}',
    ];
    final ScootColors c = ScootColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.line),
        borderRadius: ScootRadius.noteAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  template.name,
                  style: ScootType.bodyStrong.copyWith(color: c.ink),
                ),
              ),
              ScootBadge(
                label: current.isEmpty ? 'Not assigned' : 'Assigned',
                tone: current.isEmpty ? ScootTone.neutral : ScootTone.success,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            details.join(' · '),
            style: ScootType.small.copyWith(color: c.muted),
          ),
          if (current.isNotEmpty) const SizedBox(height: 6),
          for (final ScoreSheetAssignmentEvent assignment in current)
            Text(
              'Assigned to ${assignment.salesmanName} for '
              '${assignment.retailerName} '
              '(assignment v${assignment.assignmentRevision})',
              style: ScootType.body.copyWith(color: c.text2),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton(
                onPressed: () => _copy(library, template),
                child: Text('Copy', semanticsLabel: 'Copy ${template.name}'),
              ),
              OutlinedButton(
                onPressed:
                    widget.currentProductIds == null ||
                        widget.currentProductIds!.isEmpty
                    ? null
                    : () => _newVersion(template),
                child: Text(
                  'New version from current sheet',
                  semanticsLabel: 'New version of ${template.name}',
                ),
              ),
              OutlinedButton(
                onPressed: salespeople.isEmpty
                    ? null
                    : () => _assign(library, template, salespeople),
                child: Text(
                  'Assign',
                  semanticsLabel: 'Assign ${template.name}',
                ),
              ),
              if (current.isNotEmpty)
                OutlinedButton(
                  onPressed: salespeople.length < 2
                      ? null
                      : () => _reassign(library, template, salespeople),
                  child: Text(
                    'Reassign',
                    semanticsLabel: 'Reassign ${template.name}',
                  ),
                ),
              OutlinedButton(
                onPressed: () => _retire(template),
                child: Text(
                  'Retire',
                  semanticsLabel: 'Retire ${template.name}',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _historyPanel(
    BuildContext context,
    ScoreSheetLibrarySnapshot library,
  ) {
    return _panel(
      context,
      'Assignment history',
      library.events.isEmpty
          ? Text(
              'No assignments yet.',
              style: TextStyle(fontSize: 13, color: context.dso.muted),
            )
          : ListView.separated(
              itemCount: library.events.length,
              separatorBuilder: (_, _) =>
                  Divider(height: 12, color: context.dso.hairline),
              itemBuilder: (BuildContext context, int index) =>
                  _historyRow(context, library.events[index]),
            ),
    );
  }

  Widget _panel(BuildContext context, String title, Widget body) {
    return ScootCard(
      title: title,
      fill: true,
      child: body,
    );
  }

  Widget _historyRow(BuildContext context, ScoreSheetAssignmentEvent event) {
    final DateTime? at = event.createdAt?.toLocal();
    final String when = at == null
        ? 'saving'
        : '${at.year}-${_two(at.month)}-${_two(at.day)} '
              '${_two(at.hour)}:${_two(at.minute)}';
    final String change = event.previousSalesmanName.isEmpty
        ? 'Assigned to ${event.salesmanName}'
        : 'Reassigned from ${event.previousSalesmanName} to ${event.salesmanName}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${event.templateName} · assignment v${event.assignmentRevision}',
          style: ScootType.bodyStrong.copyWith(color: context.dso.ink),
        ),
        Text(
          '$change for ${event.retailerName} · $when',
          style: ScootType.small.copyWith(color: context.dso.body),
        ),
      ],
    );
  }
}

String _two(int value) => value.toString().padLeft(2, '0');

String _firstText(Map<String, dynamic> row, List<String> keys) {
  for (final String key in keys) {
    final String text = '${row[key] ?? ''}'.trim();
    if (text.isNotEmpty && text != 'null') return text;
  }
  return '';
}

List<DropdownMenuItem<String>> _salespersonItems(
  List<ScoreSheetSalesperson> people,
) {
  final Map<String, int> nameCounts = <String, int>{};
  for (final ScoreSheetSalesperson person in people) {
    nameCounts[person.name] = (nameCounts[person.name] ?? 0) + 1;
  }
  return people
      .map(
        (ScoreSheetSalesperson person) => DropdownMenuItem<String>(
          value: person.uid,
          child: Text(
            (nameCounts[person.name] ?? 0) > 1 && person.code.isNotEmpty
                ? '${person.name} (${person.code})'
                : person.name,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      )
      .toList(growable: false);
}

class _RetailerOption {
  const _RetailerOption(this.id, this.name);

  final String id;
  final String name;
}

class _AssignmentChoice {
  const _AssignmentChoice(this.salesperson, this.retailerId, this.retailerName);

  final ScoreSheetSalesperson salesperson;
  final String retailerId;
  final String retailerName;
}

class _ReassignmentChoice {
  const _ReassignmentChoice(this.current, this.salesperson);

  final ScoreSheetAssignmentEvent current;
  final ScoreSheetSalesperson salesperson;
}

class _NewVersionDialog extends StatefulWidget {
  const _NewVersionDialog({
    required this.template,
    required this.productCount,
    required this.retailerName,
    required this.onSave,
  });

  final ScoreSheetTemplate template;
  final int productCount;
  final String retailerName;
  final Future<String?> Function() onSave;

  @override
  State<_NewVersionDialog> createState() => _NewVersionDialogState();
}

class _NewVersionDialogState extends State<_NewVersionDialog>
    with _SavingDialog<_NewVersionDialog> {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'Save version ${widget.template.revision + 1} of ${widget.template.name}',
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'The new version holds the ${widget.productCount} products '
              'visible on mobile for ${widget.retailerName}. Earlier versions '
              'and existing assignments stay unchanged; new assignments use '
              'the new version.',
              style: TextStyle(color: context.dso.body),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error!,
                  style: TextStyle(color: context.dso.dangerText),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : () => _saveAndClose(widget.onSave),
          child: const Text('Save version'),
        ),
      ],
    );
  }
}

class _RetireDialog extends StatefulWidget {
  const _RetireDialog({required this.templateName, required this.onSave});

  final String templateName;
  final Future<String?> Function() onSave;

  @override
  State<_RetireDialog> createState() => _RetireDialogState();
}

class _RetireDialogState extends State<_RetireDialog>
    with _SavingDialog<_RetireDialog> {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Retire ${widget.templateName}?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'The template leaves the library, so no one can assign it '
              'again. Retailers that already use it keep their current '
              'product list, and the assignment history stays.',
              style: TextStyle(color: context.dso.body),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error!,
                  style: TextStyle(color: context.dso.dangerText),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : () => _saveAndClose(widget.onSave),
          child: const Text('Retire template'),
        ),
      ],
    );
  }
}

mixin _SavingDialog<T extends StatefulWidget> on State<T> {
  bool _saving = false;
  String? _error;

  Future<void> _saveAndClose(Future<String?> Function() save) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final String? failure = await save();
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _error = failure;
    });
  }
}

class _TemplateNameDialog extends StatefulWidget {
  const _TemplateNameDialog({
    required this.title,
    required this.confirmLabel,
    required this.existingNames,
    required this.onSave,
  });

  final String title;
  final String confirmLabel;
  final Set<String> existingNames;
  final Future<String?> Function(String name) onSave;

  @override
  State<_TemplateNameDialog> createState() => _TemplateNameDialogState();
}

class _TemplateNameDialogState extends State<_TemplateNameDialog>
    with _SavingDialog<_TemplateNameDialog> {
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _name.text.trim();
    String? error;
    if (name.isEmpty) {
      error = 'Enter a template name.';
    } else if (name.length > 120) {
      error = 'Use at most 120 characters.';
    } else if (widget.existingNames.contains(name.toLowerCase())) {
      error = 'A template with this name already exists.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    _saveAndClose(() => widget.onSave(name));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _name,
          autofocus: true,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'Template name',
            errorText: _error,
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _AssignDialog extends StatefulWidget {
  const _AssignDialog({
    required this.templateName,
    required this.salespeople,
    required this.retailers,
    required this.current,
    required this.onSave,
  });

  final String templateName;
  final List<ScoreSheetSalesperson> salespeople;
  final List<_RetailerOption> retailers;
  final List<ScoreSheetAssignmentEvent> current;
  final Future<String?> Function(_AssignmentChoice choice) onSave;

  @override
  State<_AssignDialog> createState() => _AssignDialogState();
}

class _AssignDialogState extends State<_AssignDialog>
    with _SavingDialog<_AssignDialog> {
  String? _salesmanUid;
  String? _retailerId;

  void _submit() {
    final String? salesmanUid = _salesmanUid;
    final String? retailerId = _retailerId;
    if (salesmanUid == null || retailerId == null) {
      setState(() => _error = 'Choose a salesperson and a retailer.');
      return;
    }
    final bool duplicate = widget.current.any(
      (ScoreSheetAssignmentEvent e) =>
          e.salesmanUid == salesmanUid && e.retailerId == retailerId,
    );
    if (duplicate) {
      setState(
        () => _error =
            'This salesperson already has this template for that retailer.',
      );
      return;
    }
    final _AssignmentChoice choice = _AssignmentChoice(
      widget.salespeople.firstWhere(
        (ScoreSheetSalesperson p) => p.uid == salesmanUid,
      ),
      retailerId,
      widget.retailers
          .firstWhere((_RetailerOption r) => r.id == retailerId)
          .name,
    );
    _saveAndClose(() => widget.onSave(choice));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Assign ${widget.templateName}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              "Saving replaces the retailer's mobile product list with this "
              'template. Prices are not changed.',
              style: TextStyle(fontSize: 12, color: context.dso.muted),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _salesmanUid,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Salesperson'),
              items: _salespersonItems(widget.salespeople),
              onChanged: (String? value) => setState(() {
                _salesmanUid = value;
                _error = null;
              }),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _retailerId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Retailer'),
              items: widget.retailers
                  .map(
                    (_RetailerOption retailer) => DropdownMenuItem<String>(
                      value: retailer.id,
                      child: Text(
                        retailer.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (String? value) => setState(() {
                _retailerId = value;
                _error = null;
              }),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error!,
                  style: TextStyle(color: context.dso.dangerText),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: const Text('Save assignment'),
        ),
      ],
    );
  }
}

class _ReassignDialog extends StatefulWidget {
  const _ReassignDialog({
    required this.templateName,
    required this.salespeople,
    required this.current,
    required this.onSave,
  });

  final String templateName;
  final List<ScoreSheetSalesperson> salespeople;
  final List<ScoreSheetAssignmentEvent> current;
  final Future<String?> Function(_ReassignmentChoice choice) onSave;

  @override
  State<_ReassignDialog> createState() => _ReassignDialogState();
}

class _ReassignDialogState extends State<_ReassignDialog>
    with _SavingDialog<_ReassignDialog> {
  late String _assignmentId = widget.current.first.assignmentId;
  String? _salesmanUid;

  ScoreSheetAssignmentEvent get _selected => widget.current.firstWhere(
    (ScoreSheetAssignmentEvent e) => e.assignmentId == _assignmentId,
  );

  void _submit() {
    final String? salesmanUid = _salesmanUid;
    if (salesmanUid == null) {
      setState(() => _error = 'Choose the new salesperson.');
      return;
    }
    final ScoreSheetAssignmentEvent selected = _selected;
    final bool duplicate = widget.current.any(
      (ScoreSheetAssignmentEvent e) =>
          e.salesmanUid == salesmanUid && e.retailerId == selected.retailerId,
    );
    if (duplicate) {
      setState(
        () => _error =
            'This salesperson already has this template for that retailer.',
      );
      return;
    }
    final _ReassignmentChoice choice = _ReassignmentChoice(
      selected,
      widget.salespeople.firstWhere(
        (ScoreSheetSalesperson p) => p.uid == salesmanUid,
      ),
    );
    _saveAndClose(() => widget.onSave(choice));
  }

  @override
  Widget build(BuildContext context) {
    final ScoreSheetAssignmentEvent selected = _selected;
    final List<ScoreSheetSalesperson> candidates = widget.salespeople
        .where((ScoreSheetSalesperson p) => p.uid != selected.salesmanUid)
        .toList(growable: false);
    return AlertDialog(
      title: Text('Reassign ${widget.templateName}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (widget.current.length > 1)
              DropdownButtonFormField<String>(
                initialValue: _assignmentId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Assignment'),
                items: widget.current
                    .map(
                      (ScoreSheetAssignmentEvent e) => DropdownMenuItem<String>(
                        value: e.assignmentId,
                        child: Text(
                          '${e.salesmanName} for ${e.retailerName}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (String? value) => setState(() {
                  if (value != null) _assignmentId = value;
                  _salesmanUid = null;
                  _error = null;
                }),
              )
            else
              Text(
                'Currently assigned to ${selected.salesmanName} for '
                '${selected.retailerName}.',
                style: TextStyle(color: context.dso.body),
              ),
            const SizedBox(height: 8),
            Text(
              'The earlier assignment stays in the history unchanged. The '
              "retailer's mobile product list is set to this template again.",
              style: TextStyle(fontSize: 12, color: context.dso.muted),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey<String>(_assignmentId),
              initialValue: _salesmanUid,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Salesperson'),
              items: _salespersonItems(candidates),
              onChanged: (String? value) => setState(() {
                _salesmanUid = value;
                _error = null;
              }),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error!,
                  style: TextStyle(color: context.dso.dangerText),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: const Text('Save reassignment'),
        ),
      ],
    );
  }
}
