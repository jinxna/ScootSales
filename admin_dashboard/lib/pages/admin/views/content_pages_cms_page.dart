import 'package:flutter/material.dart';

import '../../../app/permission_policy.dart';
import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../utils/cms_permissions.dart';
import '../widgets/cms_form_widgets.dart';
import '../widgets/cms_panel.dart';
import '../widgets/content_list_body.dart';
import 'package:scoot_design/scoot_design.dart';
import '../widgets/simple_content_editor.dart';

class ContentPagesCmsPage extends StatefulWidget {
  const ContentPagesCmsPage({
    super.key,
    required this.pageType,
    this.currentUser,
  });

  final String pageType;

  final UserProfile? currentUser;

  @override
  State<ContentPagesCmsPage> createState() => _ContentPagesCmsPageState();
}

class _ContentPagesCmsPageState extends State<ContentPagesCmsPage> {
  final CmsRepository _repository = CmsRepository();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _positionController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();
  String _status = 'Display';
  String? _editingId;
  bool _isSaving = false;
  int _pageStreamAttempt = 0;

  @override
  void dispose() {
    _titleController.dispose();
    _positionController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  bool get _canSave => cmsActionAllowed(
    widget.currentUser,
    'website_pages',
    _editingId == null ? PermissionAction.create : PermissionAction.edit,
  );

  Future<void> _savePage() async {
    if (_isSaving || !_canSave || !_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    final String docId =
        _editingId ??
        '${widget.pageType}_${_titleController.text.trim().toLowerCase().replaceAll(' ', '_')}';
    final bool wasEditing = _editingId != null;
    try {
      await _repository.upsertDocument(
        collectionName: 'website_pages',
        docId: docId,
        data: <String, dynamic>{
          'pageType': widget.pageType,
          'title': _titleController.text.trim(),
          'position': int.tryParse(_positionController.text.trim()) ?? 0,
          'content': _contentController.text,
          'status': _status == 'Hide' ? 'hidden' : 'active',
        },
      );
      if (!mounted) return;
      setState(() {
        _editingId = null;
        _titleController.clear();
        _positionController.clear();
        _contentController.clear();
        _status = 'Display';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wasEditing ? '$_titleLabel updated.' : '$_titleLabel added.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save $_titleLabel. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  String get _titleLabel {
    switch (widget.pageType) {
      case 'website_logo':
        return 'Website Logo';
      case 'website_title':
        return 'Website Title';
      case 'website_pages':
        return 'Website Pages';
      case 'terms':
        return 'T&C';
      case 'banner':
        return 'Home Page Banner';
      case 'tax':
        return 'Government Tax';
      default:
        return 'Content & Setting';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          flex: 3,
          child: CmsPanel(
            title: 'Add $_titleLabel',
            child: Form(
              key: _formKey,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ListView(
                  children: <Widget>[
                    CmsInput(
                      controller: _titleController,
                      label: 'Title',
                      validator: (String? value) =>
                          value == null || value.trim().isEmpty
                          ? 'Enter a title'
                          : null,
                    ),
                    const SizedBox(height: 16),
                    CmsInput(
                      controller: _positionController,
                      label: 'Position',
                      validator: (String? value) {
                        final String text = value?.trim() ?? '';
                        if (text.isEmpty) return null;
                        final int? position = int.tryParse(text);
                        return position == null || position < 0
                            ? 'Enter a non-negative whole number'
                            : null;
                      },
                    ),
                    const SizedBox(height: 16),
                    const CmsFormLabel(label: 'Status'),
                    CmsDropdown(
                      value: _status,
                      items: const <String>['Display', 'Hide'],
                      onChanged: (String? value) =>
                          setState(() => _status = value ?? 'Display'),
                    ),
                    const SizedBox(height: 16),
                    const CmsFormLabel(label: 'Content'),
                    SimpleContentEditor(controller: _contentController),
                    const SizedBox(height: 24),
                    PrimaryCmsButton(
                      label: _editingId == null ? 'Add' : 'Save',
                      onTap: _canSave ? _savePage : null,
                      isPending: _isSaving,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 3,
          child: CmsPanel(
            title: 'List $_titleLabel',
            child: StreamBuilder<List<Map<String, dynamic>>>(
              key: ValueKey<int>(_pageStreamAttempt),
              stream: _repository.watchCollection(
                'website_pages',
                orderBy: 'position',
              ),
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
                  ) {
                    final List<Map<String, dynamic>> pages =
                        (snapshot.data ?? <Map<String, dynamic>>[])
                            .where(
                              (Map<String, dynamic> item) =>
                                  item['pageType'] == widget.pageType,
                            )
                            .toList();
                    final ScootLoadPhase phase = snapshot.hasError
                        ? ScootLoadPhase.error
                        : snapshot.hasData
                        ? ScootLoadPhase.ready
                        : ScootLoadPhase.loading;
                    final Widget listBody = ContentListBody(
                      label: _titleLabel,
                      phase: phase,
                      pages: pages,
                      error: snapshot.error,
                      saving: _isSaving,
                      onRetry: () => setState(() => _pageStreamAttempt++),
                      onEdit: (Map<String, dynamic> page) {
                        setState(() {
                          _editingId = page['docId'] as String?;
                          _titleController.text =
                              page['title'] as String? ?? '';
                          _positionController.text = '${page['position'] ?? 0}';
                          _contentController.text =
                              page['content'] as String? ?? '';
                          _status =
                              (page['status'] as String? ?? '').toLowerCase() ==
                                  'hidden'
                              ? 'Hide'
                              : 'Display';
                        });
                      },
                    );
                    return Column(
                      children: <Widget>[
                        CmsMiniToolbar(itemCount: pages.length),
                        Expanded(child: listBody),
                      ],
                    );
                  },
            ),
          ),
        ),
      ],
    );
  }
}
