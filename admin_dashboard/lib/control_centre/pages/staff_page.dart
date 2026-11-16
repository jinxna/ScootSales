import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import '../store/cc_store.dart';
import '../widgets/cc_command.dart';
import '../widgets/cc_common.dart';
import '../widgets/cc_shell.dart';

class StaffPage extends StatefulWidget {
  const StaffPage({super.key, required this.store});

  final CcStore store;

  @override
  State<StaffPage> createState() => _StaffPageState();
}

class _StaffPageState extends State<StaffPage> {
  Loaded<StaffDirectory>? _directory;
  bool _busy = false;

  CcStore get store => widget.store;

  static const List<String> _roleNames = <String>[
    'owner',
    'operator',
    'engineer',
    'support',
  ];

  static const List<(String, String, String)>
  _roles = <(String, String, String)>[
    (
      'owner',
      'Everything',
      'Sees all companies and money. Approves risky changes. Changes package prices. Adds and removes staff.',
    ),
    (
      'operator',
      'Daily accounts work',
      'Starts new companies, creates and sends invoices, records payments, checks payments, handles plan requests and failed emails. Asks for approval on risky changes.',
    ),
    (
      'engineer',
      'Setup',
      'Sees companies and onboarding. Enters the setup details for each company.',
    ),
    (
      'support',
      'Help a company',
      'Opens a company only while that company has granted support access. Sees no money.',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final Loaded<StaffDirectory> loaded = await Loaded.of(
      store.api.staffDirectory(),
    );
    if (mounted) setState(() => _directory = loaded);
  }

  Widget _roleDropdown(String value, ValueChanged<String?> onChanged) =>
      DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Role'),
        items: <DropdownMenuItem<String>>[
          for (final String role in _roleNames)
            DropdownMenuItem<String>(value: role, child: Text(roleLabel(role))),
        ],
        onChanged: onChanged,
      );

  Future<void> _invite(List<String> domains) async {
    final TextEditingController name = TextEditingController();
    final TextEditingController email = TextEditingController();
    String role = 'operator';
    final bool sent = await showCcCommand(
      context,
      title: 'Add staff member',
      confirmLabel: 'Send invitation',
      reasonLabel: null,
      body: StatefulBuilder(
        builder: (BuildContext context, StateSetter setInner) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: name,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Name',
                counterText: '',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'Work email',
                helperText: domains.isEmpty
                    ? null
                    : 'Allowed: ${domains.map((String d) => '@$d').join(', ')}',
              ),
            ),
            const SizedBox(height: 14),
            _roleDropdown(
              role,
              (String? v) => setInner(() => role = v ?? role),
            ),
          ],
        ),
      ),
      run: (String reason, String key) => CmdResult.run(
        () => store.api.inviteStaff(
          email: email.text.trim(),
          name: name.text.trim(),
          role: role,
        ),
        done: 'The invitation was sent.',
      ),
    );
    name.dispose();
    email.dispose();
    if (sent) await _load();
  }

  Future<void> _changeRole(StaffPerson person) async {
    String role = person.role;
    final bool saved = await showCcCommand(
      context,
      title: 'Change role',
      confirmLabel: 'Save role',
      reasonLabel: null,
      body: StatefulBuilder(
        builder: (BuildContext context, StateSetter setInner) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(person.email, style: Cc.small),
            const SizedBox(height: 12),
            _roleDropdown(
              role,
              (String? v) => setInner(() => role = v ?? role),
            ),
          ],
        ),
      ),
      run: (String reason, String key) => CmdResult.run(
        () => store.api.changeStaffRole(person.staffId, role),
        done: 'The role was changed.',
      ),
    );
    if (saved) await _load();
  }

  Future<void> _disable(StaffPerson person) async {
    final bool invited = person.isInvited;
    final bool ok = await showCcConfirm(
      context,
      title: invited ? 'Cancel invitation?' : 'Turn off access?',
      message: invited
          ? 'The invitation link sent to ${person.email} stops working. You can invite the right email address after this.'
          : '${person.email} is signed out everywhere and cannot sign in again until you invite them again.',
      confirmLabel: invited ? 'Cancel invitation' : 'Turn off access',
      danger: true,
    );
    if (!ok || !mounted || _busy) return;
    setState(() => _busy = true);
    String message = invited
        ? 'The invitation was cancelled.'
        : 'Access was turned off.';
    try {
      await store.api.disableStaff(person.staffId);
    } on StaffApiException catch (error) {
      message = friendlyError(error);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    announce(context, message);
    await _load();
  }

  Future<void> _remove(StaffPerson person) async {
    final bool ok = await showCcConfirm(
      context,
      title: 'Remove ${person.name ?? person.email}?',
      message:
          '${person.email} is removed from the staff list for good. This cannot be undone. The audit log keeps its past entries. You can invite the same email address again later.',
      confirmLabel: 'Remove person',
      danger: true,
    );
    if (!ok || !mounted || _busy) return;
    setState(() => _busy = true);
    String message = '${person.email} was removed.';
    try {
      await store.api.removeStaff(person.staffId);
    } on StaffApiException catch (error) {
      message = friendlyError(error);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    announce(context, message);
    await _load();
  }

  String _statusText(StaffPerson person) {
    if (person.isInvited) {
      return 'Invited, link ends ${dayText(person.inviteExpiresAt)}';
    }
    return switch (person.status) {
      'active' => 'Active',
      'accepting' => 'Accepting the invitation',
      _ => 'Turned off',
    };
  }

  Widget _people(StaffDirectory directory) => CcTable(
    columns: const <CcColumn>[
      CcColumn('Person', flex: 3),
      CcColumn('Role', width: 110),
      CcColumn('Status', flex: 2, hideBelow: 760),
      CcColumn('Last sign-in', width: 150, hideBelow: 900),
      CcColumn('Actions', width: 280, right: true),
    ],
    rows: <CcTableRow>[
      for (final StaffPerson person in directory.people)
        CcTableRow(
          cells: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  person.name ?? person.email,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Cc.ink,
                  ),
                ),
                Text(person.email, style: Cc.small),
              ],
            ),
            Text(roleLabel(person.role)),
            Text(_statusText(person)),
            Text(
              person.lastSignInAt == null
                  ? 'Never'
                  : dateTimeText(person.lastSignInAt),
              style: Cc.numbers,
            ),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.end,
              children: <Widget>[
                if (person.isActive || person.isInvited)
                  OutlinedButton(
                    onPressed: _busy ? null : () => _changeRole(person),
                    child: Text(
                      'Change role',
                      semanticsLabel: 'Change role for ${person.email}',
                    ),
                  ),
                if ((person.isActive || person.isInvited) &&
                    person.email != store.me)
                  TextButton(
                    onPressed: _busy ? null : () => _disable(person),
                    child: Text(
                      person.isInvited
                          ? 'Cancel invitation for ${person.email}'
                          : 'Turn off access for ${person.email}',
                    ),
                  ),
                if (person.status == 'disabled' &&
                    store.profile?.isOwner == true)
                  TextButton(
                    onPressed: _busy ? null : () => _remove(person),
                    child: Text(
                      'Remove',
                      semanticsLabel: 'Remove ${person.email}',
                    ),
                  ),
              ],
            ),
          ],
        ),
    ],
    empty: const CcEmptyState(
      title: 'No staff yet',
      message: 'Add the first staff member.',
    ),
  );

  Widget _matrix() => CcCard(
    title: 'What each role can do',
    child: Column(
      children: <Widget>[
        for (int i = 0; i < _roles.length; i++) ...<Widget>[
          if (i > 0) const Divider(height: 1, color: Cc.line),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 180,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        roleLabel(_roles[i].$1),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Cc.ink,
                        ),
                      ),
                      Text(_roles[i].$2, style: Cc.small),
                    ],
                  ),
                ),
                Expanded(child: Text(_roles[i].$3)),
              ],
            ),
          ),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final Loaded<StaffDirectory>? loaded = _directory;
    return CcPage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CcPageHeader(
            'Staff and access',
            actions: <Widget>[
              if (loaded?.value != null)
                FilledButton.icon(
                  onPressed: () => _invite(loaded!.value!.domains),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add staff member'),
                ),
            ],
          ),
          if (loaded == null)
            const CcSkeleton()
          else if (loaded.value == null)
            CcErrorState(what: 'staff', message: loaded.error!, onRetry: _load)
          else ...<Widget>[
            CcBanner(
              tone: loaded.value!.soloOwnerActive ? Tone.warn : Tone.info,
              text: !loaded.value!.soloOwnerSetting
                  ? 'Solo owner setting: off. Every risky change needs approval by another owner or operator.'
                  : loaded.value!.soloOwnerActive
                  ? 'Solo owner setting: on. You are the only approver, so you can approve your own requests and payment checks. Each one is marked "solo approval" in the audit log.'
                  : 'Solo owner setting: on, but not in use. There is more than one approver, so another owner or operator must approve.',
            ),
            if (!loaded.value!.soloOwnerActive &&
                loaded.value!.people
                        .where((StaffPerson p) => p.isApprover)
                        .length <
                    2)
              const CcBanner(
                text:
                    'Fewer than 2 active approvers (owner or operator). A second person must approve risky changes, so they cannot finish. Add a second owner or operator before go-live.',
              ),
            _people(loaded.value!),
          ],
          const SizedBox(height: 16),
          _matrix(),
        ],
      ),
    );
  }
}
