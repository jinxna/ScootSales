import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import '../store/cc_store.dart';
import '../widgets/cc_command.dart';
import '../widgets/cc_common.dart';
import '../widgets/cc_nav.dart';
import '../widgets/cc_shell.dart';
import '../widgets/draft_fields.dart';

class NewCompanyPage extends StatefulWidget {
  const NewCompanyPage({super.key, required this.store, required this.nav});

  final CcStore store;
  final CcNav nav;

  @override
  State<NewCompanyPage> createState() => _NewCompanyPageState();
}

class _NewCompanyPageState extends State<NewCompanyPage> {
  final GlobalKey<DraftFormFieldsState> _fields =
      GlobalKey<DraftFormFieldsState>();
  Loaded<List<StaffPackage>>? _catalogue;
  String? _key, _error;
  Map<String, Object?>? _body;
  bool _busy = false, _uncertain = false;
  StaffOnboardingDraft? _created;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final Loaded<List<StaffPackage>> loaded = await Loaded.of(
      widget.store.api.packages(),
    );
    if (mounted) setState(() => _catalogue = loaded);
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_uncertain) {
      if (!_fields.currentState!.validate()) return;
      _key = newKey();
      _body = _fields.currentState!.body();
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final StaffOnboardingDraft created = await widget.store.api
          .createOnboardingDraft(_body!, key: _key!);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _uncertain = false;
        _created = created;
      });
      widget.store.refreshDrafts();
    } on StaffApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _uncertain = isUncertain(error);
        _error = _uncertain
            ? 'The result is not confirmed. The draft may already exist. Press Check again to retry with the same details.'
            : friendlyError(error);
        if (!_uncertain) {
          _key = null;
          _body = null;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _uncertain = true;
        _error =
            'The result is not confirmed. The draft may already exist. Press Check again to retry with the same details.';
      });
    }
  }

  Widget _done(StaffOnboardingDraft created) => CcCard(
    title: 'Draft created',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          created.legalName,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'The code ${codeText(created.workspace)} is reserved until ${dayText(created.endsAt)}. Open the checklist to connect the Firebase project. The kind of company (New or Existing) is read from the project.',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton(
              onPressed: () => widget.nav.openOnboarding(created.draftId),
              child: const Text('Open checklist'),
            ),
            TextButton(
              onPressed: () => setState(() {
                _created = null;
                _key = null;
                _body = null;
              }),
              child: const Text('Add another'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _formCard() {
    final Loaded<List<StaffPackage>>? catalogue = _catalogue;
    return CcCard(
      title: 'Company details',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (catalogue == null)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (catalogue.value == null)
            CcBanner(
              tone: Tone.danger,
              text: catalogue.error!,
              action: OutlinedButton(
                onPressed: _load,
                child: const Text('Try again'),
              ),
            )
          else
            DraftFormFields(
              key: _fields,
              packages: catalogue.value!,
              locked: _busy || _uncertain,
            ),
          const SizedBox(height: 14),
          if (_error != null) CcBanner(text: _error!, tone: Tone.danger),
          Wrap(
            spacing: 8,
            children: <Widget>[
              FilledButton(
                onPressed: _busy || catalogue?.value == null ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_uncertain ? 'Check again' : 'Create draft'),
              ),
              TextButton(
                onPressed: _busy || _uncertain
                    ? null
                    : () => widget.nav.go(CcSection.onboarding),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.store.profile!.canCreateCompany) {
      return const CcPage(
        child: CcEmptyState(
          title: 'Your role cannot add companies',
          message: 'Only the owner or operator starts a new company.',
        ),
      );
    }
    return CcPage(
      maxWidth: 820,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const CcPageHeader('Add company'),
          _created == null ? _formCard() : _done(_created!),
        ],
      ),
    );
  }
}
