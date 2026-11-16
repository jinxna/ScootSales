import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../security/user_access_index.dart';
import '../../../security/user_management_rules.dart';
import '../widgets/cms_form_widgets.dart';

class UserBranchField extends StatelessWidget {
  const UserBranchField({
    super.key,
    required this.role,
    required this.value,
    required this.branches,
    required this.branchesLoaded,
    required this.onChanged,
    this.onOpenBranches,
    this.readOnly = false,
  });

  final String role;
  final String value;
  final List<Map<String, dynamic>> branches;
  final bool branchesLoaded;
  final ValueChanged<String?> onChanged;
  final VoidCallback? onOpenBranches;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final bool required = UserManagementRules.roleRequiresBranch(role);
    final Set<String> seen = <String>{''};
    final List<DropdownMenuItem<String>> items = <DropdownMenuItem<String>>[
      DropdownMenuItem<String>(
        value: '',
        child: Text(required ? 'Select a branch' : 'Not linked'),
      ),
    ];
    for (final Map<String, dynamic> branch in branches) {
      final String id =
          ((branch['branchId'] ?? branch['docId']) as Object? ?? '')
              .toString()
              .trim();
      if (id.isEmpty || !seen.add(id)) continue;
      final String text =
          ((branch['branchName'] ?? branch['name']) as Object? ?? id)
              .toString()
              .trim();
      items.add(
        DropdownMenuItem<String>(
          value: id,
          child: Text(
            text.isEmpty ? id : text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    final bool noBranchesExist = branchesLoaded && items.length == 1;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        CmsFormLabel(label: required ? 'Branch *' : 'Branch'),
        if (required && noBranchesExist && !readOnly)
          Container(
            key: const ValueKey<String>('user-branch-empty'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Create a branch first',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.onErrorContainer,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Supervisors, branch managers and salesmen must belong to a '
                  'branch, and no branches exist yet.',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onErrorContainer,
                  ),
                ),
                if (onOpenBranches != null)
                  TextButton.icon(
                    onPressed: onOpenBranches,
                    icon: const Icon(ScootIcons.team, size: 18),
                    label: const Text('Open Branches'),
                  ),
              ],
            ),
          ),
        DropdownButtonFormField<String>(
          key: const ValueKey<String>('user-branch-field'),
          isExpanded: true,
          initialValue:
              items.any((DropdownMenuItem<String> i) => i.value == value)
              ? value
              : '',
          items: items,
          onChanged: readOnly ? null : onChanged,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: (String? chosen) => readOnly
              ? null
              : UserManagementRules.branchError(
                  role: role,
                  branchId: chosen ?? value,
                ),
        ),
      ],
    );
  }
}

class SupervisorOption {
  const SupervisorOption({
    required this.employeeCode,
    required this.name,
    required this.codes,
  });

  final String employeeCode;
  final String name;
  final Set<String> codes;

  factory SupervisorOption.fromUser(Map<String, dynamic> user) {
    final String code =
        ((user['employeeCode'] ?? user['userId']) as Object? ?? '')
            .toString()
            .trim();
    final String name = ((user['name'] ?? user['displayName']) as Object? ?? '')
        .toString()
        .trim();
    return SupervisorOption(
      employeeCode: code,
      name: name.isEmpty ? code : name,
      codes: UserAccessIndex.parseAssignedSalesmanCodes(
        user['assignedSalesmanCodes'],
      ).toSet(),
    );
  }
}

class UserSupervisorField extends StatelessWidget {
  const UserSupervisorField({
    super.key,
    required this.supervisors,
    required this.value,
    required this.editingSalesmanCode,
    required this.onChanged,
    this.readOnly = false,
  });

  final List<SupervisorOption> supervisors;
  final String value;
  final String editingSalesmanCode;
  final ValueChanged<String?> onChanged;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final Set<String> seen = <String>{''};
    final List<DropdownMenuItem<String>> items = <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(value: '', child: Text('Not linked')),
    ];
    for (final SupervisorOption option in supervisors) {
      if (option.employeeCode.isEmpty || !seen.add(option.employeeCode)) {
        continue;
      }
      final bool full = UserManagementRules.supervisorOptionDisabled(
        codes: option.codes,
        editingSalesmanCode: editingSalesmanCode,
      );
      items.add(
        DropdownMenuItem<String>(
          value: option.employeeCode,
          enabled: !full || option.employeeCode == value,
          child: Text(
            full
                ? '${UserManagementRules.supervisorOptionLabel(option.name, option.codes.length)} - full'
                : UserManagementRules.supervisorOptionLabel(
                    option.name,
                    option.codes.length,
                  ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const CmsFormLabel(label: 'Assigned Supervisor'),
        DropdownButtonFormField<String>(
          key: const ValueKey<String>('user-supervisor-field'),
          isExpanded: true,
          initialValue:
              items.any((DropdownMenuItem<String> i) => i.value == value)
              ? value
              : '',
          items: items,
          onChanged: readOnly ? null : onChanged,
        ),
      ],
    );
  }
}
