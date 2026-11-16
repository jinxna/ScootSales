import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../staff_api_client.dart';

class DraftFormFields extends StatefulWidget {
  const DraftFormFields({
    super.key,
    required this.packages,
    this.initial,
    this.locked = false,
    this.adminOnly = false,
  });

  final List<StaffPackage> packages;
  final StaffOnboardingDraft? initial;
  final bool locked;
  final bool adminOnly;

  @override
  State<DraftFormFields> createState() => DraftFormFieldsState();
}

class DraftFormFieldsState extends State<DraftFormFields> {
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?.legalName,
  );
  late final TextEditingController _workspace = TextEditingController(
    text: widget.initial?.workspace.toUpperCase(),
  );
  late final TextEditingController _adminName = TextEditingController(
    text: widget.initial?.adminName,
  );
  late final TextEditingController _adminEmail = TextEditingController(
    text: widget.initial?.adminEmail,
  );
  late final TextEditingController _adminCode = TextEditingController(
    text: widget.initial?.adminEmployeeCode,
  );
  late final TextEditingController _billingEmail = TextEditingController(
    text: widget.initial?.billingEmail,
  );
  late String? _planId = widget.initial?.planId;
  late String _interval = widget.initial?.billingInterval ?? 'monthly';

  static final RegExp _workspaceShape = RegExp(
    r'^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$',
  );
  static final TextInputFormatter _capitals = TextInputFormatter.withFunction(
    (TextEditingValue old, TextEditingValue next) =>
        next.copyWith(text: next.text.toUpperCase()),
  );
  static final RegExp _emailShape = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void dispose() {
    _name.dispose();
    _workspace.dispose();
    _adminName.dispose();
    _adminEmail.dispose();
    _adminCode.dispose();
    _billingEmail.dispose();
    super.dispose();
  }

  bool validate() => _form.currentState!.validate();

  void clear() {
    _name.clear();
    _workspace.clear();
    _adminName.clear();
    _adminEmail.clear();
    _adminCode.clear();
    _billingEmail.clear();
    setState(() => _planId = null);
  }

  Map<String, Object?> body() => widget.adminOnly
      ? _adminBody()
      : <String, Object?>{
          'legalName': _name.text.trim(),
          'workspace': _workspace.text.trim().toLowerCase(),
          if (_adminName.text.trim().isNotEmpty)
            'adminName': _adminName.text.trim(),
          if (_adminEmail.text.trim().isNotEmpty)
            'adminEmail': _adminEmail.text.trim(),
          if (_adminCode.text.trim().isNotEmpty)
            'adminEmployeeCode': _adminCode.text.trim(),
          if (_billingEmail.text.trim().isNotEmpty)
            'billingEmail': _billingEmail.text.trim(),
          'planId': ?_planId,
          if (_planId != null) 'billingInterval': _interval,
        };

  Map<String, Object?> _adminBody() => <String, Object?>{
    if (_adminName.text.trim().isNotEmpty) 'adminName': _adminName.text.trim(),
    if (_adminEmail.text.trim().isNotEmpty)
      'adminEmail': _adminEmail.text.trim(),
    if (_adminCode.text.trim().isNotEmpty)
      'adminEmployeeCode': _adminCode.text.trim(),
    if (_billingEmail.text.trim().isNotEmpty)
      'billingEmail': _billingEmail.text.trim(),
  };

  String? _optionalEmail(String? value) =>
      value == null ||
          value.trim().isEmpty ||
          _emailShape.hasMatch(value.trim())
      ? null
      : 'Enter a valid email address.';

  Widget _text(
    TextEditingController controller,
    String label, {
    String? helper,
    int maxLength = 120,
    bool capitals = false,
    bool companyField = false,
    String? Function(String?)? validator,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      controller: controller,
      readOnly: widget.locked || (companyField && widget.adminOnly),
      maxLength: maxLength,
      inputFormatters: capitals ? <TextInputFormatter>[_capitals] : null,
      decoration: InputDecoration(labelText: label, helperText: helper),
      validator: validator,
    ),
  );

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _text(
          _name,
          'Company name',
          companyField: true,
          helper: widget.adminOnly
              ? 'Locked after the project is connected.'
              : null,
          validator: (String? value) =>
              value == null || value.trim().isEmpty ? 'Required' : null,
        ),
        _text(
          _workspace,
          'Workspace code',
          companyField: true,
          maxLength: 32,
          capitals: true,
          helper:
              'Letters, digits and dashes, shown in capitals. Staff type it to find the company.',
          validator: (String? value) =>
              value != null &&
                  _workspaceShape.hasMatch(value.trim().toLowerCase())
              ? null
              : 'Use 3 to 32 letters, digits or dashes.',
        ),
        _text(_adminName, 'First administrator name'),
        _text(
          _adminEmail,
          'First administrator email',
          maxLength: 254,
          helper: 'The invitation goes to this email.',
          validator: _optionalEmail,
        ),
        _text(
          _adminCode,
          'First administrator employee code',
          maxLength: 40,
          helper: 'The code this person uses to sign in.',
        ),
        _text(
          _billingEmail,
          'Billing email',
          maxLength: 254,
          helper: 'Invoices and receipts are sent here.',
          validator: _optionalEmail,
        ),
        Wrap(
          spacing: 16,
          runSpacing: 14,
          children: <Widget>[
            SizedBox(
              width: 280,
              child: DropdownButtonFormField<String>(
                initialValue: _planId,
                isExpanded: true,
                hint: const Text('Choose later'),
                decoration: const InputDecoration(labelText: 'Package'),
                items: <DropdownMenuItem<String>>[
                  for (final StaffPackage p in widget.packages)
                    DropdownMenuItem<String>(
                      value: p.planId,
                      child: Text(p.name),
                    ),
                ],
                onChanged: widget.locked || widget.adminOnly
                    ? null
                    : (String? value) => setState(() => _planId = value),
              ),
            ),
            SizedBox(
              width: 200,
              child: DropdownButtonFormField<String>(
                initialValue: _interval,
                decoration: const InputDecoration(labelText: 'Billing period'),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(
                    value: 'monthly',
                    child: Text('Monthly'),
                  ),
                  DropdownMenuItem<String>(
                    value: 'yearly',
                    child: Text('Yearly'),
                  ),
                ],
                onChanged: widget.locked || widget.adminOnly
                    ? null
                    : (String? value) =>
                          setState(() => _interval = value ?? 'monthly'),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
