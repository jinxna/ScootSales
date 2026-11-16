import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/safe_doc_id.dart';
import '../../../utils/user_facing_error.dart';
import '../../../widgets/cms_feedback.dart';
import '../widgets/cms_form_widgets.dart';
import '../widgets/cms_panel.dart';
import '../../../widgets/slow_loading.dart';

abstract class BranchStore {
  Stream<List<Map<String, dynamic>>> watchUsers();
  Stream<List<Map<String, dynamic>>> watchBranches();

  Future<void> createBranch(String docId, Map<String, dynamic> data);
  Future<void> updateBranch(String docId, Map<String, dynamic> data);
}

class FirestoreBranchStore implements BranchStore {
  FirestoreBranchStore();

  final CmsRepository _repository = CmsRepository();

  @override
  Stream<List<Map<String, dynamic>>> watchUsers() =>
      _repository.watchCollection('users', orderBy: 'name');

  @override
  Stream<List<Map<String, dynamic>>> watchBranches() =>
      _repository.watchCollection('branches', orderBy: 'branchName');

  @override
  Future<void> createBranch(String docId, Map<String, dynamic> data) =>
      _repository.createDocumentIfAbsent(
        collectionName: 'branches',
        docId: docId,
        data: <String, dynamic>{
          ...data,
          'createdAt': FieldValue.serverTimestamp(),
        },
        duplicateMessage:
            'a branch with this name already exists. Edit it from the '
            'directory instead.',
      );

  @override
  Future<void> updateBranch(String docId, Map<String, dynamic> data) =>
      _repository.upsertDocument(
        collectionName: 'branches',
        docId: docId,
        data: data,
      );
}

class BranchManagementCmsPage extends StatefulWidget {
  const BranchManagementCmsPage({
    super.key,
    required this.currentUser,
    this.store,
  });

  final UserProfile currentUser;
  final BranchStore? store;

  @override
  State<BranchManagementCmsPage> createState() =>
      _BranchManagementCmsPageState();
}

class _BranchManagementCmsPageState extends State<BranchManagementCmsPage> {
  late final BranchStore _store = widget.store ?? FirestoreBranchStore();
  late final Stream<List<Map<String, dynamic>>> _usersStream = _store
      .watchUsers();
  late final Stream<List<Map<String, dynamic>>> _branchesStream = _store
      .watchBranches();
  List<Map<String, dynamic>> _latestBranches = <Map<String, dynamic>>[];
  bool _saving = false;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _branchNameController = TextEditingController();
  String _status = 'active';
  String _branchManagerId = '';
  String? _editingId;

  @override
  void dispose() {
    _branchNameController.dispose();
    super.dispose();
  }

  void _editBranch(Map<String, dynamic> branch) {
    setState(() {
      _editingId = branch['docId'] as String?;
      _branchNameController.text = branch['branchName'] as String? ?? '';
      _branchManagerId = branch['branchManagerId'] as String? ?? '';
      _status = branch['status'] as String? ?? 'active';
    });
  }

  Map<String, dynamic>? _existingBranchFor(String name, String docId) {
    final String wanted = name.trim().toLowerCase();
    for (final Map<String, dynamic> branch in _latestBranches) {
      final String existingName = '${branch['branchName'] ?? ''}'
          .trim()
          .toLowerCase();
      if (branch['docId'] == docId || existingName == wanted) return branch;
    }
    return null;
  }

  Future<void> _saveBranch() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    final String name = _branchNameController.text.trim();
    final bool creating = _editingId == null;
    final String docId =
        _editingId ?? safeDocId(name, fallbackPrefix: 'branch');

    if (creating) {
      final Map<String, dynamic>? existing = _existingBranchFor(name, docId);
      if (existing != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('A branch named "$name" already exists.'),
            backgroundColor: context.dso.dangerText,
            action: SnackBarAction(
              label: 'Open it',
              onPressed: () => _editBranch(existing),
            ),
          ),
        );
        return;
      }
    }

    setState(() => _saving = true);
    try {
      final Map<String, dynamic> data = <String, dynamic>{
        'branchId': docId,
        'branchName': name,
        'branchManagerId': _branchManagerId,
        'status': _status,
      };
      if (creating) {
        await _store.createBranch(docId, data);
      } else {
        await _store.updateBranch(docId, data);
      }
      if (!mounted) return;
      _clearForm();
      showCmsToast(context, creating ? 'Branch added.' : 'Branch updated.');
    } catch (error) {
      if (!mounted) return;
      showCmsToast(
        context,
        userFacingError(error, action: 'save the branch'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _clearForm() {
    setState(() {
      _editingId = null;
      _branchNameController.clear();
      _branchManagerId = '';
      _status = 'active';
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _usersStream,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> userSnapshot,
          ) {
            final List<Map<String, dynamic>> branchManagers =
                (userSnapshot.data ?? <Map<String, dynamic>>[])
                    .where(
                      (Map<String, dynamic> user) =>
                          ((user['role'] ?? user['user_group']) as Object? ??
                                  '')
                              .toString() ==
                          'branch_manager',
                    )
                    .toList();

            final List<DropdownMenuItem<String>> branchManagerItems =
                <DropdownMenuItem<String>>[
                  const DropdownMenuItem<String>(
                    value: '',
                    child: Text('Not linked'),
                  ),
                  ...branchManagers.map(
                    (Map<String, dynamic> user) => DropdownMenuItem<String>(
                      value: (user['employeeCode'] as String? ?? '').trim(),
                      child: Text((user['name'] as String? ?? '').trim()),
                    ),
                  ),
                ];

            return LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final bool twoColumns = constraints.maxWidth >= 1100;

                final Widget form = CmsPanel(
                  title: _editingId == null ? 'Add Branch' : 'Edit Branch',
                  child: Form(
                    key: _formKey,
                    child: ListView(
                      padding: const EdgeInsets.all(18),
                      children: <Widget>[
                        const CmsFormLabel(label: 'Branch Name'),
                        TextFormField(
                          controller: _branchNameController,
                          validator: (String? value) =>
                              value == null || value.trim().isEmpty
                              ? 'Enter a branch name'
                              : null,
                        ),
                        const SizedBox(height: 16),
                        const CmsFormLabel(label: 'Branch Manager'),
                        DropdownButtonFormField<String>(
                          initialValue:
                              branchManagerItems.any(
                                (DropdownMenuItem<String> item) =>
                                    item.value == _branchManagerId,
                              )
                              ? _branchManagerId
                              : '',
                          items: branchManagerItems,
                          onChanged: (String? value) =>
                              setState(() => _branchManagerId = value ?? ''),
                        ),
                        const SizedBox(height: 16),
                        const CmsFormLabel(label: 'Status'),
                        CmsDropdown(
                          value: _status,
                          items: const <String>['active', 'suspended'],
                          onChanged: (String? value) =>
                              setState(() => _status = value ?? 'active'),
                          width: double.infinity,
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: <Widget>[
                            PrimaryCmsButton(
                              label: _editingId == null
                                  ? 'Save Branch'
                                  : 'Update Branch',
                              isPending: _saving,
                              onTap: _saveBranch,
                            ),
                            const SizedBox(width: 10),
                            OutlinedButton(
                              onPressed: _saving ? null : _clearForm,
                              child: const Text('Reset'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );

                final Widget list = CmsPanel(
                  title: 'Branch Directory',
                  child: StreamBuilder<List<Map<String, dynamic>>>(
                    stream: _branchesStream,
                    builder:
                        (
                          BuildContext context,
                          AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
                        ) {
                          if (snapshot.hasError) {
                            return Center(
                              child: Text(
                                userFacingError(
                                  snapshot.error!,
                                  action: 'load branches',
                                ),
                              ),
                            );
                          }
                          final List<Map<String, dynamic>> branches =
                              snapshot.data ?? <Map<String, dynamic>>[];
                          _latestBranches = branches;
                          if (branches.isEmpty) {
                            return _EmptyBranches(
                              loading:
                                  snapshot.connectionState ==
                                  ConnectionState.waiting,
                            );
                          }
                          return ListView.separated(
                            padding: const EdgeInsets.all(18),
                            itemCount: branches.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 10),
                            itemBuilder: (BuildContext context, int index) {
                              final Map<String, dynamic> branch =
                                  branches[index];
                              return Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant,
                                  ),
                                ),
                                child: Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: <Widget>[
                                          Text(
                                            '${branch['branchName'] ?? '-'}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'Manager: ${branch['branchManagerId'] ?? 'Not linked'}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: context.dso.muted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    OutlinedButton(
                                      onPressed: () => _editBranch(branch),
                                      child: const Text('Edit'),
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                        },
                  ),
                );

                if (twoColumns) {
                  return Row(
                    children: <Widget>[
                      Expanded(child: form),
                      const SizedBox(width: 12),
                      Expanded(child: list),
                    ],
                  );
                }
                return ListView(
                  children: <Widget>[
                    SizedBox(height: 430, child: form),
                    const SizedBox(height: 12),
                    SizedBox(height: 430, child: list),
                  ],
                );
              },
            );
          },
    );
  }
}

class _EmptyBranches extends StatelessWidget {
  const _EmptyBranches({required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    if (loading) return const SlowLoading();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.store_mall_directory_outlined,
              size: 40,
              color: context.dso.muted,
            ),
            const SizedBox(height: 12),
            const Text(
              'Create your first branch',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              'Users need a branch before they can be added. Use the form to '
              'add one.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.dso.muted),
            ),
          ],
        ),
      ),
    );
  }
}
