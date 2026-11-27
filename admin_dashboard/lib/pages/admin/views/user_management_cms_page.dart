import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:uuid/uuid.dart';

import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../repositories/user_management_repository.dart';
import '../../../security/user_management_rules.dart';
import '../../../services/auth_service.dart';
import '../../../services/platform_api_client.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/user_facing_error.dart';
import '../../../utils/user_management_utils.dart';
import '../widgets/cms_form_widgets.dart';
import '../widgets/cms_panel.dart';
import '../widgets/user_management_deletion_requests_panel.dart';
import '../widgets/user_management_invitations_panel.dart';
import '../widgets/user_management_remove_profile_dialog.dart';
import '../widgets/user_management_team_chart.dart';
import '../../../widgets/dso_filter_controls.dart';
import '../../../widgets/repair_accounts_check.dart';
import 'user_management_fields.dart';

class UserManagementCmsPage extends StatefulWidget {
  const UserManagementCmsPage({
    super.key,
    required this.currentUser,
    this.onOpenBranches,
  });

  final UserProfile currentUser;

  final VoidCallback? onOpenBranches;

  @override
  State<UserManagementCmsPage> createState() => _UserManagementCmsPageState();
}

class _UserManagementCmsPageState extends State<UserManagementCmsPage> {
  final CmsRepository _repository = CmsRepository();
  final UserManagementRepository _userManagementRepository =
      UserManagementRepository();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  AutovalidateMode _autovalidateMode = AutovalidateMode.disabled;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _employeeCodeController = TextEditingController();
  final TextEditingController _contactNumberController =
      TextEditingController();

  String _role = 'salesman';
  String _selectedBranchId = '';
  String _selectedSupervisorId = '';
  String? _editingId;
  String? _editingUid;
  String _originalRole = '';
  String _originalBranchId = '';
  String _originalSupervisorId = '';
  String _originalEmployeeCode = '';
  bool _isSaving = false;
  bool _showTeamChart = false;
  final Set<String> _togglingIds = <String>{};
  final GlobalKey<UserManagementInvitationsPanelState> _invitationsKey =
      GlobalKey<UserManagementInvitationsPanelState>();
  String? _inviteKey;
  String? _inviteFingerprint;
  String? _replacedInvitationId;

  bool _isSelfRecord({String? docId, String? uid}) {
    final String myDoc = widget.currentUser.docId.trim();
    final String myUid = (widget.currentUser.uid ?? '').trim();
    final String d = (docId ?? '').trim();
    final String u = (uid ?? '').trim();
    return (myDoc.isNotEmpty && d == myDoc) || (myUid.isNotEmpty && u == myUid);
  }

  bool get _isSelfEdit =>
      _editingId != null && _isSelfRecord(docId: _editingId, uid: _editingUid);

  void _toast(String message, {bool isError = false}) {
    if (!mounted) return;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: isError ? TextStyle(color: scheme.onErrorContainer) : null,
        ),
        backgroundColor: isError ? scheme.errorContainer : null,
        duration: Duration(seconds: isError ? 8 : 4),
      ),
    );
  }

  String _describeError(Object error, {required String action}) {
    if (error is UserManagementFormProblem) return error.message;
    if (error is FirebaseAuthException) {
      return AuthService.instance.describeUserManagementError(error);
    }
    if (error is FirebaseException) {
      return userFacingError(error, action: action);
    }
    if (error is StateError) return error.message;
    if (error.runtimeType.toString() == '_Exception') {
      final String text = error.toString().replaceFirst('Exception: ', '');
      if (text.isNotEmpty) return text;
    }
    return userFacingError(error, action: action);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _employeeCodeController.dispose();
    _contactNumberController.dispose();
    super.dispose();
  }

  Future<void> _saveUser() async {
    if (_isSaving) return;
    if (!_formKey.currentState!.validate()) {
      setState(() => _autovalidateMode = AutovalidateMode.onUserInteraction);
      _toast('Fix the highlighted fields and try again.', isError: true);
      return;
    }
    final String? branchProblem = _isSelfEdit
        ? null
        : UserManagementRules.branchError(
            role: _role,
            branchId: _selectedBranchId,
          );
    if (branchProblem != null) {
      _toast(branchProblem, isError: true);
      return;
    }

    setState(() => _isSaving = true);

    final bool isCreating = _editingId == null;
    final bool isSelfEdit = _isSelfEdit;
    String docId = _editingId ?? '';
    String savedCodeChange = '';

    try {
      final String email = _emailController.text.trim().toLowerCase();
      final String name = _nameController.text.trim();

      if (isSelfEdit) {
        final Map<String, dynamic> safePayload =
            UserManagementRules.selfEditProfilePayload(
              name: name,
              contactNumber: _contactNumberController.text,
              email: _emailController.text,
              updatedAt: FieldValue.serverTimestamp(),
            );
        final WriteBatch selfSave = _userManagementRepository.createBatch();
        _userManagementRepository.queueUserProfile(
          selfSave,
          docId,
          safePayload,
        );
        await _userManagementRepository.upsertUserAccessIndex(
          batch: selfSave,
          uid: _editingUid,
          actorUid: widget.currentUser.uid ?? '',
          userDocId: docId,
          email: email,
          role: _role,
          branchId: _selectedBranchId,
          supervisorId: _selectedSupervisorId,
        );
        await _userManagementRepository.commit(selfSave);
        await _recordAudit(docId, safePayload, isCreate: false);
        if (!mounted) return;
        _toast('Your profile was updated.');
        _clearForm();
        return;
      }

      final String employeeCode =
          UserManagementRules.employeeCodeToSave(
            typed: _employeeCodeController.text,
            storedCode: _originalEmployeeCode,
          ) ??
          await _generateEmployeeCode(_role);

      final UserManagementSupervisorPlan plan = await _userManagementRepository
          .planSupervisorChanges(
            oldRole: _originalRole,
            oldEmployeeCode: _originalEmployeeCode,
            oldSupervisorId: _originalSupervisorId,
            employeeCode: employeeCode,
            newRole: _role,
            newSupervisorId: _selectedSupervisorId,
            newBranchId: _selectedBranchId,
            oldBranchId: _originalBranchId,
          );
      if (plan.orphans.isNotEmpty) {
        await _explainDemotionBlocked(plan.orphans.length);
        return;
      }

      if (isCreating) {
        await _inviteUser(employeeCode: employeeCode, name: name, email: email);
        return;
      }

      if (employeeCode != _originalEmployeeCode) {
        final String uid = (_editingUid ?? '').trim();
        if (uid.isEmpty) {
          _toast(
            'This person has not accepted the invitation yet, so the employee code cannot change.',
          );
          return;
        }
        try {
          await PlatformApiClient().changeEmployeeCode(
            uid,
            employeeCode: employeeCode,
            idempotencyKey: const Uuid().v4(),
          );
        } on PlatformApiException catch (error) {
          _toast(error.message);
          return;
        }
        if (docId == _originalEmployeeCode) docId = employeeCode;
        _editingId = docId;
        _originalEmployeeCode = employeeCode;
        savedCodeChange = employeeCode;
      }

      if (_role != _originalRole) {
        await _changeRole();
      }

      final Map<String, dynamic> profileData =
          UserManagementUtils.buildProfilePayload(
            authUid: (_editingUid ?? '').trim(),
            name: name,
            email: email,
            branchId: _selectedBranchId,
            supervisorId: _selectedSupervisorId,
            contactNumber: _contactNumberController.text.trim(),
            isCreating: false,
            provisioningByUid: '',
          );
      final WriteBatch userSave = _userManagementRepository.createBatch();
      _userManagementRepository.queueUserProfile(
        userSave,
        docId,
        <String, dynamic>{
          ...profileData,
          'updatedAt': FieldValue.serverTimestamp(),
        },
      );
      await _userManagementRepository.upsertUserAccessIndex(
        batch: userSave,
        uid: _editingUid,
        actorUid: widget.currentUser.uid ?? '',
        userDocId: docId,
        email: email,
        role: _role,
        branchId: _selectedBranchId,
        supervisorId: _selectedSupervisorId,
      );

      _userManagementRepository.queueSupervisorPlan(userSave, plan);
      await _userManagementRepository.commit(userSave);

      _originalRole = _role;
      _originalBranchId = _selectedBranchId;
      _originalSupervisorId = _selectedSupervisorId;
      _originalEmployeeCode = employeeCode;

      await _recordAudit(docId, profileData, isCreate: false);

      if (!mounted) return;
      final String who = name.isEmpty ? email : name;
      _toast('Saved changes to $who.');
      _clearForm();
    } catch (error) {
      final String problem = _describeError(
        error,
        action: isCreating ? 'create the invitation' : 'save the user',
      );
      _toast(
        savedCodeChange.isEmpty
            ? problem
            : 'The employee code is now $savedCodeChange, but the other '
                  'changes were not saved. $problem Press Update Profile '
                  'again to finish.',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _changeRole() async {
    final String uid = (_editingUid ?? '').trim();
    if (uid.isEmpty) {
      throw StateError(
        'This person has no sign-in account yet, so their role cannot be '
        'changed here.',
      );
    }
    String supervisorUid = '';
    if (_role == 'salesman' && _selectedSupervisorId.isNotEmpty) {
      supervisorUid = await _userManagementRepository.resolveSupervisorUid(
        _selectedSupervisorId,
      );
    }
    await PlatformApiClient().changeAccountRole(
      uid,
      role: _role,
      branchId: _selectedBranchId,
      supervisorUid: supervisorUid.isEmpty ? null : supervisorUid,
      idempotencyKey: const Uuid().v4(),
    );
    _originalRole = _role;
  }

  Future<void> _inviteUser({
    required String employeeCode,
    required String name,
    required String email,
  }) async {
    if (_role == 'developer') {
      throw StateError('Developer accounts cannot be created by invitation.');
    }
    final String phone = _contactNumberController.text.trim();
    String supervisorUid = '';
    if (_role == 'salesman' && _selectedSupervisorId.isNotEmpty) {
      supervisorUid = await _userManagementRepository.resolveSupervisorUid(
        _selectedSupervisorId,
      );
      if (supervisorUid.isEmpty) {
        throw StateError(
          'The chosen supervisor has no sign-in account yet. Choose another '
          'supervisor or invite the supervisor first.',
        );
      }
    }
    final InvitationRequest request = InvitationRequest(
      displayName: name,
      role: _role,
      employeeCode: employeeCode,
      branchId: _selectedBranchId,
      email: email.isEmpty ? null : email,
      phone: phone.isEmpty ? null : phone,
      supervisorUid: supervisorUid.isEmpty ? null : supervisorUid,
    );
    if (_inviteKey == null || _inviteFingerprint != request.fingerprint) {
      _inviteKey = const Uuid().v4();
      _inviteFingerprint = request.fingerprint;
    }
    final String? replacedInvitationId = _replacedInvitationId;
    if (replacedInvitationId != null) {
      await PlatformApiClient().revokeInvitation(replacedInvitationId);
      _replacedInvitationId = null;
    }
    final CreatedInvitation created = await PlatformApiClient()
        .createInvitation(request, idempotencyKey: _inviteKey!);
    _inviteKey = null;
    _inviteFingerprint = null;
    if (!mounted) return;
    _clearForm();
    _invitationsKey.currentState?.refresh(expand: true);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) =>
          InvitationCreatedDialog(invitation: created, personName: name),
    );
  }

  Future<void> _recordAudit(
    String docId,
    Map<String, dynamic> data, {
    required bool isCreate,
  }) async {
    try {
      await _repository.recordDocumentUpsert(
        collectionName: 'users',
        isCreate: isCreate,
        data: data,
        docId: docId,
      );
    } catch (_) {}
  }

  Future<void> _explainDemotionBlocked(int count) => showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Move the team first'),
      content: Text(UserManagementUtils.supervisorRoleChangeBlockedText(count)),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );

  Future<String> _generateEmployeeCode(String role) async {
    final List<Map<String, dynamic>> users = await _repository
        .getCollectionOnce('users', limit: 3000);
    final String prefix = switch (role) {
      'admin' => 'A',
      'supervisor' => 'SV',
      'branch_manager' => 'BM',
      _ => 'S',
    };

    int highest = 0;
    for (final Map<String, dynamic> user in users) {
      final String code =
          ((user['employeeCode'] ?? user['userId']) as Object? ?? '')
              .toString()
              .toUpperCase();
      if (!code.startsWith(prefix)) continue;
      final String numericPart = code.replaceFirst(prefix, '');
      final int? parsed = int.tryParse(numericPart);
      if (parsed != null && parsed > highest) highest = parsed;
    }

    return '$prefix${(highest + 1).toString().padLeft(4, '0')}';
  }

  double _stackedPanelHeight(double maxHeight, {required double fallback}) {
    return ((maxHeight > 0 ? maxHeight * 0.82 : fallback).clamp(
      600.0,
      860.0,
    )).toDouble();
  }

  void _prefillInviteAgain(InvitationRecord row) {
    _clearForm();
    setState(() {
      _nameController.text = row.displayName;
      if (row.signInId.contains('@')) _emailController.text = row.signInId;
      _role = row.role.isEmpty ? 'salesman' : row.role;
      _replacedInvitationId = row.invitationId;
    });
    _toast(
      'Check the details, add the employee code, and send the invitation '
      'again. The old code is cancelled when you send.',
    );
  }

  void _clearForm() {
    setState(() {
      _autovalidateMode = AutovalidateMode.disabled;
      _editingId = null;
      _editingUid = null;
      _replacedInvitationId = null;
      _originalRole = '';
      _originalBranchId = '';
      _originalSupervisorId = '';
      _originalEmployeeCode = '';
      _nameController.clear();
      _emailController.clear();
      _employeeCodeController.clear();
      _contactNumberController.clear();
      _role = 'salesman';
      _selectedBranchId = '';
      _selectedSupervisorId = '';
    });
  }

  Future<void> _toggleUserStatus(Map<String, dynamic> user) async {
    final String docId = (user['docId'] as String? ?? '').trim();
    if (docId.isEmpty || _togglingIds.contains(docId)) return;

    final String uid = ((user['uid'] ?? '') as Object).toString().trim();
    if (_isSelfRecord(docId: docId, uid: uid)) {
      _toast(
        'You cannot suspend your own account. Ask another administrator.',
        isError: true,
      );
      return;
    }

    final String status = UserManagementUtils.userStatus(user);
    final bool nextIsActive = status != UserProfile.statusActive;
    final String email = ((user['email'] ?? '') as Object).toString().trim();
    final String role = ((user['role'] ?? user['user_group'] ?? '') as Object)
        .toString()
        .trim();
    final String branchId =
        ((user['branchId'] ?? user['branch_id'] ?? '') as Object)
            .toString()
            .trim();
    final String displayName = UserManagementUtils.readUserName(user).isEmpty
        ? (email.isEmpty ? 'this user' : email)
        : UserManagementUtils.readUserName(user);

    if (uid.isNotEmpty &&
        UserManagementRules.roleRequiresBranch(role) &&
        branchId.isEmpty) {
      _toast(
        '$displayName has no branch yet. Choose Edit, select a branch and '
        'save before changing their status.',
        isError: true,
      );
      return;
    }

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(
          UserManagementRules.statusConfirmTitle(status, displayName),
        ),
        content: Text(UserManagementRules.statusConfirmBody(status)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(UserManagementRules.statusActionLabel(status)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _togglingIds.add(docId));
    try {
      if (uid.isEmpty) {
        throw StateError(
          '$displayName has no sign-in account yet, so there is nothing to '
          'change.',
        );
      }
      final PlatformApiClient api = PlatformApiClient();
      if (nextIsActive) {
        await api.reactivateAccount(uid, idempotencyKey: const Uuid().v4());
      } else {
        await api.revokeAccount(uid);
      }
      _toast(
        nextIsActive
            ? '$displayName is active again and can sign in.'
            : '$displayName is suspended and blocked from signing in.',
      );
    } catch (error) {
      _toast(
        _describeError(
          error,
          action: nextIsActive ? 'activate the user' : 'suspend the user',
        ),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _togglingIds.remove(docId));
    }
  }

  Future<void> _deleteProfile(Map<String, dynamic> user) async {
    if (!widget.currentUser.isActive ||
        widget.currentUser.role != UserProfile.roleAdmin) {
      _showProfileMessage(
        'Only an active Admin can remove another user profile.',
        isError: true,
      );
      return;
    }

    final String docId = UserManagementUtils.firstNonEmptyField(user, <String>[
      'docId',
    ]);
    final String uid = UserManagementUtils.firstNonEmptyField(user, <String>[
      'uid',
      'userUid',
    ]);
    final String role = UserProfile.normalizeRole(
      UserManagementUtils.firstNonEmptyField(user, <String>[
        'role',
        'user_group',
      ]),
      email: UserManagementUtils.readUserEmail(user),
    );
    final String employeeCode = UserManagementUtils.readUserCode(user);
    final String displayName = UserManagementUtils.readUserName(user).isEmpty
        ? 'this user'
        : UserManagementUtils.readUserName(user);
    final String displayEmail = UserManagementUtils.readUserEmail(user);

    if (docId.isEmpty || docId == 'current_session_user') {
      _showProfileMessage(
        'This row has no saved profile, so there is nothing to '
        'remove. Reload the directory and try again.',
        isError: true,
      );
      return;
    }
    final String actorDocId = widget.currentUser.docId.trim();
    final String actorUid = widget.currentUser.uid?.trim() ?? '';
    if ((actorDocId.isNotEmpty && docId == actorDocId) ||
        (actorUid.isNotEmpty && uid == actorUid)) {
      _showProfileMessage(
        'You cannot remove your own dashboard profile. Ask another active '
        'administrator to remove it, or suspend the account instead.',
        isError: true,
      );
      return;
    }

    int linkedSalesmen = 0;
    if (role == 'supervisor' && employeeCode.isNotEmpty) {
      try {
        linkedSalesmen = await _userManagementRepository.countLinkedSalesmen(
          employeeCode,
        );
      } catch (_) {}
    }
    if (!mounted) return;

    final String confirmLabel =
        UserManagementUtils.readUserName(user).isNotEmpty
        ? displayName
        : (displayEmail.isNotEmpty ? displayEmail : employeeCode);
    final UserManagementRemoveProfileChoice? choice =
        await showDialog<UserManagementRemoveProfileChoice>(
          context: context,
          builder: (BuildContext context) => UserManagementRemoveProfileDialog(
            name: displayName,
            confirmText: confirmLabel,
            canSuspend: UserManagementUtils.userStatus(user) == 'active',
            linkedSalesmen: linkedSalesmen,
          ),
        );
    if (choice == UserManagementRemoveProfileChoice.suspend) {
      await _toggleUserStatus(user);
      return;
    }
    if (choice != UserManagementRemoveProfileChoice.remove) return;

    try {
      final PlatformApiClient api = PlatformApiClient();
      if (uid.isEmpty) {
        await api.removeProfile(docId, idempotencyKey: const Uuid().v4());
      } else {
        await api.removeAccount(uid, idempotencyKey: const Uuid().v4());
      }
    } catch (error) {
      _showProfileMessage(
        userFacingError(error, action: 'remove $displayName'),
        isError: true,
      );
      return;
    }

    _showProfileMessage(
      uid.isEmpty
          ? 'Profile removed.'
          : 'Profile removed. This person can no longer sign in. Their orders, '
                'routes and visits were kept.',
    );
    if (_editingId == docId) {
      _clearForm();
    }
  }

  void _showProfileMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: isError ? TextStyle(color: scheme.onErrorContainer) : null,
        ),
        backgroundColor: isError ? scheme.errorContainer : null,
        duration: isError
            ? const Duration(seconds: 8)
            : const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.currentUser.isAdmin) {
      return const CmsPanel(
        title: 'Assign a role',
        child: Center(
          child: Text('Only Admin can create or edit user accounts.'),
        ),
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool useTwoColumns = constraints.maxWidth >= 1200;
        final Widget formPanel = _buildFormPanel();
        final Widget directoryPanel = _buildDirectoryPanel();

        if (useTwoColumns) {
          return Column(
            children: <Widget>[
              _repairTools(),
              const SizedBox(height: 12),
              UserManagementInvitationsPanel(
                key: _invitationsKey,
                onInviteAgain: _prefillInviteAgain,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(flex: 4, child: formPanel),
                    const SizedBox(width: 16),
                    Expanded(flex: 5, child: directoryPanel),
                  ],
                ),
              ),
            ],
          );
        }

        final double stackedPanelHeight = _stackedPanelHeight(
          constraints.maxHeight,
          fallback: 720,
        );

        return ListView(
          children: <Widget>[
            _repairTools(),
            const SizedBox(height: 12),
            UserManagementInvitationsPanel(
              key: _invitationsKey,
              onInviteAgain: _prefillInviteAgain,
            ),
            const SizedBox(height: 12),
            SizedBox(height: stackedPanelHeight, child: formPanel),
            const SizedBox(height: 16),
            SizedBox(height: stackedPanelHeight, child: directoryPanel),
          ],
        );
      },
    );
  }

  Widget _repairTools() {
    final ScootColors c = ScootColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.line),
        borderRadius: ScootRadius.cardAll,
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(ScootIcons.settings),
          title: Text(
            'Account repair tools',
            style: ScootType.cardTitle.copyWith(color: c.ink),
          ),
          subtitle: Text(
            'Scan profiles and sign-in accounts. Nothing changes until you confirm.',
            style: ScootType.small.copyWith(color: c.muted),
          ),
          childrenPadding: EdgeInsets.zero,
          children: <Widget>[
            RepairAccountsCheck(currentUser: widget.currentUser),
          ],
        ),
      ),
    );
  }

  Widget _buildFormPanel() {
    return CmsPanel(
      title: _editingId == null ? 'Assign a role' : 'Edit Assigned Role',
      trailing: const _UiBadge(label: 'Account linked'),
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _repository.watchCollection('branches', orderBy: 'branchName'),
        builder:
            (
              BuildContext context,
              AsyncSnapshot<List<Map<String, dynamic>>> branchSnapshot,
            ) {
              return StreamBuilder<List<Map<String, dynamic>>>(
                stream: _repository.watchCollection('users', orderBy: 'name'),
                builder:
                    (
                      BuildContext context,
                      AsyncSnapshot<List<Map<String, dynamic>>> userSnapshot,
                    ) {
                      final List<Map<String, dynamic>> branches =
                          branchSnapshot.data ?? <Map<String, dynamic>>[];
                      final List<Map<String, dynamic>> users =
                          userSnapshot.data ?? <Map<String, dynamic>>[];
                      bool inSelectedBranch(Map<String, dynamic> user) =>
                          _selectedBranchId.isEmpty ||
                          UserManagementRules.sameBranch(
                            UserManagementUtils.firstNonEmptyField(
                              user,
                              const <String>['branchId', 'branch_id'],
                            ),
                            _selectedBranchId,
                          );
                      final List<Map<String, dynamic>> supervisors =
                          UserManagementUtils.supervisors(users)
                              .where(
                                (Map<String, dynamic> supervisor) =>
                                    inSelectedBranch(supervisor) ||
                                    UserManagementUtils.readUserCode(
                                          supervisor,
                                        ) ==
                                        _selectedSupervisorId,
                              )
                              .toList();

                      return Form(
                        key: _formKey,
                        autovalidateMode: _autovalidateMode,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                          children: <Widget>[
                            Wrap(
                              spacing: 12,
                              runSpacing: 16,
                              children: <Widget>[
                                SizedBox(
                                  width: 320,
                                  child: _dropdownField(
                                    label: 'Role',
                                    value: _role,
                                    items: widget.currentUser.isDeveloper
                                        ? const <String>[
                                            'developer',
                                            'admin',
                                            'branch_manager',
                                            'supervisor',
                                            'salesman',
                                          ]
                                        : const <String>[
                                            'admin',
                                            'branch_manager',
                                            'supervisor',
                                            'salesman',
                                          ],
                                    onChanged: _isSelfEdit
                                        ? null
                                        : (String? value) {
                                            setState(() {
                                              _role = value ?? 'salesman';
                                              if (_role != 'salesman') {
                                                _selectedSupervisorId = '';
                                              }
                                            });
                                          },
                                  ),
                                ),
                                SizedBox(
                                  width: 320,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      const CmsFormLabel(
                                        label: 'Employee Code',
                                      ),
                                      TextFormField(
                                        controller: _employeeCodeController,
                                        enabled: !_isSelfEdit,
                                        decoration: InputDecoration(
                                          hintText: 'Auto-generated if empty',
                                          helperMaxLines: 2,
                                          helperText: _editingId != null
                                              ? 'The new code must not be used by anyone else.'
                                              : 'Leave empty to auto-generate from the selected role.',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (_isSelfEdit) ...<Widget>[
                              const SizedBox(height: 8),
                              Text(
                                'This is your own account. Another '
                                'administrator must change your role or status.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 12,
                              runSpacing: 16,
                              children: <Widget>[
                                SizedBox(
                                  width: 320,
                                  child: _textField(
                                    controller: _nameController,
                                    label: 'Full Name',
                                    validator: (String? value) =>
                                        value == null || value.trim().isEmpty
                                        ? 'Enter a name'
                                        : null,
                                  ),
                                ),
                                SizedBox(
                                  width: 320,
                                  child: _textField(
                                    controller: _emailController,
                                    label: 'Email',
                                    enabled: _editingId == null,
                                    validator: (String? value) {
                                      final String text = (value ?? '').trim();
                                      if (text.isEmpty) {
                                        return _editingId == null
                                            ? (_contactNumberController.text
                                                      .trim()
                                                      .isEmpty
                                                  ? 'Enter an email or a contact number'
                                                  : null)
                                            : 'Enter an email';
                                      }
                                      if (!RegExp(
                                        r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                                      ).hasMatch(text)) {
                                        return 'Enter a valid email address';
                                      }
                                      return null;
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 12,
                              runSpacing: 16,
                              children: <Widget>[
                                SizedBox(
                                  width: 320,
                                  child: _textField(
                                    controller: _contactNumberController,
                                    label: 'Contact Number',
                                    validator: (String? value) {
                                      final String text = (value ?? '').trim();
                                      if (_editingId != null || text.isEmpty) {
                                        return null;
                                      }
                                      return text
                                                  .replaceAll(RegExp(r'\D'), '')
                                                  .length <
                                              4
                                          ? 'Enter a number with at least 4 digits'
                                          : null;
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 12,
                              runSpacing: 16,
                              children: <Widget>[
                                SizedBox(
                                  width: 320,
                                  child: UserBranchField(
                                    role: _role,
                                    value: _selectedBranchId,
                                    branches: branches,
                                    branchesLoaded: branchSnapshot.hasData,
                                    readOnly: _isSelfEdit,
                                    onOpenBranches: widget.onOpenBranches,
                                    onChanged: (String? value) => setState(() {
                                      _selectedBranchId = value ?? '';
                                      if (!supervisors.any(
                                        (Map<String, dynamic> supervisor) =>
                                            UserManagementUtils.readUserCode(
                                                  supervisor,
                                                ) ==
                                                _selectedSupervisorId &&
                                            inSelectedBranch(supervisor),
                                      )) {
                                        _selectedSupervisorId = '';
                                      }
                                    }),
                                  ),
                                ),
                                if (_role == 'salesman')
                                  SizedBox(
                                    width: 320,
                                    child: UserSupervisorField(
                                      supervisors: supervisors
                                          .map(SupervisorOption.fromUser)
                                          .toList(growable: false),
                                      value: _selectedSupervisorId,
                                      editingSalesmanCode:
                                          _originalEmployeeCode,
                                      readOnly: _isSelfEdit,
                                      onChanged: (String? value) => setState(
                                        () =>
                                            _selectedSupervisorId = value ?? '',
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.outlineVariant,
                                ),
                              ),
                              child: Text(
                                'Creating a user sends an invitation: you get a one-time code to give to the person, who sets their own password. Suspending a user blocks dashboard access through the saved account status.',
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.55,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            Row(
                              children: <Widget>[
                                PrimaryCmsButton(
                                  label: _editingId == null
                                      ? 'Create User'
                                      : 'Update Profile',
                                  icon: ScootIcons.check,
                                  onTap: _saveUser,
                                  isPending: _isSaving,
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton(
                                  onPressed: _isSaving ? null : _clearForm,
                                  child: const Text('Reset'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
              );
            },
      ),
    );
  }

  Widget _buildDirectoryPanel() {
    return CmsPanel(
      title: 'Assigned Users Directory',
      trailing: const _UiBadge(label: 'Live records'),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints directoryConstraints) {
          final bool compactDirectory = directoryConstraints.maxHeight < 360.0;
          final double deletionListHeight = compactDirectory
              ? 140.0
              : (directoryConstraints.maxHeight - 176.0)
                    .clamp(0.0, 140.0)
                    .toDouble();
          return StreamBuilder<List<Map<String, dynamic>>>(
            stream: _repository.watchCollection('users', orderBy: 'name'),
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
                ) {
                  final Widget viewSwitch = Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
                    child: SegmentedButton<bool>(
                      segments: const <ButtonSegment<bool>>[
                        ButtonSegment<bool>(
                          value: false,
                          icon: Icon(ScootIcons.layers),
                          label: Text('Directory'),
                        ),
                        ButtonSegment<bool>(
                          value: true,
                          icon: Icon(ScootIcons.team),
                          label: Text('Team chart'),
                        ),
                      ],
                      selected: <bool>{_showTeamChart},
                      onSelectionChanged: (Set<bool> picked) =>
                          setState(() => _showTeamChart = picked.first),
                    ),
                  );
                  if (_showTeamChart) {
                    final Widget chart = UserManagementTeamChart(
                      users: snapshot.data ?? <Map<String, dynamic>>[],
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        viewSwitch,
                        if (compactDirectory)
                          SizedBox(height: 420, child: chart)
                        else
                          Expanded(child: chart),
                      ],
                    );
                  }
                  final List<Map<String, dynamic>> users =
                      UserManagementUtils.filterUsers(
                        snapshot.data ?? <Map<String, dynamic>>[],
                        query: _searchController.text,
                        includeDevelopers: widget.currentUser.isDeveloper,
                      );

                  final Widget searchRow = Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
                    child: LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints box) {
                        return Wrap(
                          spacing: DsoFilterMetrics.gap,
                          runSpacing: DsoFilterMetrics.gap,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            DsoFilterSearchField(
                              controller: _searchController,
                              width: box.maxWidth < 420 ? box.maxWidth : 420,
                              hintText:
                                  'Search by name, email, or employee code',
                              onChanged: (_) => setState(() {}),
                            ),
                            Text(
                              '${users.length} users',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  );
                  final Widget requestPanel = Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: UserManagementDeletionRequestsPanel(
                      listHeight: deletionListHeight,
                      repository: _userManagementRepository,
                    ),
                  );
                  final Widget userList = users.isEmpty
                      ? const Center(child: Text('No users found yet.'))
                      : ListView.separated(
                          primary: false,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          itemCount: users.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (BuildContext context, int index) {
                            final Map<String, dynamic> user = users[index];
                            final String role = UserProfile.normalizeRole(
                              ((user['role'] ??
                                              user['user_group'] ??
                                              user['roleLabel'])
                                          as Object? ??
                                      '')
                                  .toString(),
                            );
                            final String displayName =
                                UserManagementUtils.readUserName(user);
                            final String displayEmail =
                                UserManagementUtils.readUserEmail(user);
                            final String displayCode =
                                UserManagementUtils.readUserCode(user);
                            return Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.outlineVariant,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      CircleAvatar(
                                        radius: 18,
                                        backgroundColor: Theme.of(
                                          context,
                                        ).colorScheme.primaryContainer,
                                        child: Text(
                                          displayName.isEmpty
                                              ? 'U'
                                              : displayName.characters.first
                                                    .toUpperCase(),
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onPrimaryContainer,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Text(
                                              displayName.isEmpty
                                                  ? '-'
                                                  : displayName,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 16,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              '${displayEmail.isEmpty ? '-' : displayEmail} • ${displayCode.isEmpty ? '-' : displayCode}',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                                height: 1.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      _statusBadge(
                                        context,
                                        UserManagementUtils.userStatus(user),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: <Widget>[
                                      _DetailChip(
                                        label:
                                            'Role: ${UserManagementUtils.roleLabel(role)}',
                                      ),
                                      if ('${user['branchId'] ?? user['branch_id'] ?? ''}'
                                          .isNotEmpty)
                                        _DetailChip(
                                          label:
                                              'Branch: ${user['branchId'] ?? user['branch_id']}',
                                        ),
                                      if ('${user['supervisorId'] ?? user['supervisor_id'] ?? ''}'
                                          .isNotEmpty)
                                        _DetailChip(
                                          label:
                                              'Supervisor: ${user['supervisorId'] ?? user['supervisor_id']}',
                                        ),
                                      if (_deletionRequestedLabel(user)
                                          case final String deletionLabel)
                                        _DetailChip(label: deletionLabel),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: <Widget>[
                                      OutlinedButton.icon(
                                        onPressed: () {
                                          setState(() {
                                            _editingId =
                                                user['docId'] as String?;
                                            _editingUid =
                                                user['uid'] as String?;
                                            _originalRole = role;
                                            _originalSupervisorId =
                                                (user['supervisorId']
                                                    as String? ??
                                                user['supervisor_id']
                                                    as String? ??
                                                '');
                                            _originalEmployeeCode = displayCode;
                                            _nameController.text = displayName;
                                            _emailController.text =
                                                displayEmail;
                                            _employeeCodeController.text =
                                                displayCode;
                                            _contactNumberController.text =
                                                (user['contactNumber']
                                                    as String? ??
                                                user['contact_number']
                                                    as String? ??
                                                user['phone'] as String? ??
                                                '');
                                            _role = role;
                                            _selectedBranchId =
                                                (user['branchId'] as String? ??
                                                user['branch_id'] as String? ??
                                                user['branch'] as String? ??
                                                '');
                                            _originalBranchId =
                                                _selectedBranchId;
                                            _selectedSupervisorId =
                                                (user['supervisorId']
                                                    as String? ??
                                                user['supervisor_id']
                                                    as String? ??
                                                '');
                                          });
                                        },
                                        icon: const Icon(
                                          ScootIcons.edit,
                                          size: 18,
                                        ),
                                        label: const Text('Edit'),
                                      ),
                                      if (!_isSelfRecord(
                                        docId: user['docId'] as String?,
                                        uid: user['uid']?.toString(),
                                      ))
                                        OutlinedButton.icon(
                                          onPressed:
                                              _togglingIds.contains(
                                                (user['docId'] as String?) ??
                                                    '',
                                              )
                                              ? null
                                              : () => _toggleUserStatus(user),
                                          icon: const Icon(
                                            ScootIcons.paused,
                                            size: 18,
                                          ),
                                          label: Text(
                                            UserManagementRules.statusActionLabel(
                                              UserManagementUtils.userStatus(
                                                user,
                                              ),
                                            ),
                                          ),
                                        ),
                                      if (widget.currentUser.role ==
                                          UserProfile.roleAdmin)
                                        OutlinedButton.icon(
                                          onPressed: () => _deleteProfile(user),
                                          icon: const Icon(
                                            ScootIcons.remove,
                                            size: 18,
                                          ),
                                          label: const Text('Remove Profile'),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        );

                  if (compactDirectory) {
                    return ListView(
                      padding: EdgeInsets.zero,
                      children: <Widget>[
                        viewSwitch,
                        searchRow,
                        if (widget.currentUser.role == UserProfile.roleAdmin)
                          requestPanel,
                        SizedBox(height: 280, child: userList),
                      ],
                    );
                  }

                  return Column(
                    children: <Widget>[
                      viewSwitch,
                      searchRow,
                      if (widget.currentUser.role == UserProfile.roleAdmin)
                        requestPanel,
                      Expanded(child: userList),
                    ],
                  );
                },
          );
        },
      ),
    );
  }

  Widget _textField({
    required TextEditingController controller,
    required String label,
    String? Function(String?)? validator,
    bool obscureText = false,
    bool enabled = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        CmsFormLabel(label: label),
        TextFormField(
          controller: controller,
          enabled: enabled,
          obscureText: obscureText,
          validator: validator,
        ),
      ],
    );
  }

  Widget _dropdownField({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String?>? onChanged,
  }) {
    final List<String> uniqueItems = items.toSet().toList(growable: false);
    final String safeValue = uniqueItems.contains(value)
        ? value
        : uniqueItems.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        CmsFormLabel(label: label),
        DropdownButtonFormField<String>(
          initialValue: safeValue,
          items: uniqueItems
              .map(
                (String item) => DropdownMenuItem<String>(
                  value: item,
                  child: Text(UserManagementUtils.roleLabel(item)),
                ),
              )
              .toList(),
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _UiBadge extends StatelessWidget {
  const _UiBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

String? _deletionRequestedLabel(Map<String, dynamic> user) {
  final Object? reasons = user['disabledReasons'];
  if (reasons is! List || !reasons.contains('deletion_requested')) return null;
  final Object? requestedAt = user['deletionRequestedAt'];
  if (requestedAt is! Timestamp) return 'Deletion requested';
  final DateTime date = requestedAt.toDate();
  final String month = date.month.toString().padLeft(2, '0');
  final String day = date.day.toString().padLeft(2, '0');
  return 'Deletion requested ${date.year}-$month-$day';
}

class _DetailChip extends StatelessWidget {
  const _DetailChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

Widget _statusBadge(BuildContext context, String value) {
  final bool active = value.toLowerCase() == 'active';
  final ColorScheme scheme = Theme.of(context).colorScheme;
  final bool dark = scheme.brightness == Brightness.dark;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    decoration: BoxDecoration(
      color: active
          ? (dark ? DsoTokens.successSurfaceDark : DsoTokens.successSoft)
          : scheme.errorContainer,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      active ? 'Active' : 'Suspended',
      style: TextStyle(
        color: active
            ? (dark ? DsoTokens.successTextDark : DsoTokens.successText)
            : scheme.onErrorContainer,
        fontWeight: FontWeight.w700,
        fontSize: 12,
      ),
    ),
  );
}
