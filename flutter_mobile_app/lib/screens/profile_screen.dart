import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:scoot_design/scoot_design.dart';
import '../providers/auth_provider.dart';
import '../providers/gps_provider.dart';
import '../models/user_model.dart';
import '../services/company_lifecycle_monitor.dart';
import '../services/held_work_sync.dart';
import 'edit_profile_screen.dart'
    show EditProfileScreen, buildProfileImage, editProfileRoleLabel;
import 'delete_account_screen.dart';
import 'legal_document_screen.dart';
import 'overview_screen.dart' show AppBottomNav;
import 'planner_screen.dart';
import 'my_visits_screen.dart';

Future<bool> confirmSignOut(
  BuildContext context, {
  required Future<bool> Function() hasWork,
  required Future<void> Function() upload,
  bool deletingAccount = false,
}) async {
  String note = '';
  while (true) {
    final bool waiting = await hasWork();
    if (!context.mounted) return false;
    if (deletingAccount && !waiting) return true;
    final String? choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(waiting ? 'Work is still waiting to upload' : 'Sign out?'),
        content: Text(
          waiting
              ? '${note}Some sales or visits on this phone have not reached your company yet. Tap Upload now while you are online. ${deletingAccount ? 'If you delete your account anyway, they are lost.' : 'If you sign out anyway, they stay on this phone and are sent when you sign in again on this phone.'}'
              : 'Work that is not sent yet stays on this phone. When this account signs in again on this phone and is online, the phone sends it by itself. Work held during a company pause is sent as soon as the company accepts it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          if (waiting)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'sign_out'),
              child: Text(
                deletingAccount ? 'Delete anyway' : 'Sign out anyway',
              ),
            ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, waiting ? 'upload' : 'sign_out'),
            child: Text(waiting ? 'Upload now' : 'Sign Out'),
          ),
        ],
      ),
    );
    if (choice != 'upload') return choice == 'sign_out';
    await upload();
    note = 'Not everything is uploaded yet. Check your connection. ';
  }
}

Future<void> uploadWaitingWork() async {
  await CompanyLifecycleMonitor.instance.refresh();
  try {
    await FirebaseFirestore.instance.waitForPendingWrites().timeout(
      const Duration(seconds: 15),
    );
  } catch (_) {}
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        final user = authProvider.user;
        return Scaffold(
          backgroundColor: ScootColors.of(context).page,
          appBar: ScootPhoneAppBar(
            title: 'Profile',
            onBack: Navigator.of(context).canPop()
                ? () => Navigator.of(context).maybePop()
                : null,
            actions: <Widget>[
              if (user != null)
                ScootPhoneAction(
                  icon: ScootIcons.edit,
                  label: 'Edit profile',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => EditProfileScreen(user: user),
                    ),
                  ),
                ),
            ],
          ),
          body: user == null
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    vertical: ScootSpace.phoneGutter,
                  ),
                  child: Column(
                    children: [
                      _ProfileHeader(user: user),
                      const SizedBox(height: 16),
                      const _QuickAccessSection(),
                      const SizedBox(height: 16),
                      _AccountSection(user: user),
                      if (user.hasSalespersonRole) ...[
                        const SizedBox(height: 16),
                        _WorkSessionSection(user: user),
                      ],
                      const SizedBox(height: 16),
                      _SettingsSection(user: user),
                      const SizedBox(height: 24),
                      _SignOutButton(),
                      const _DeleteAccountRow(),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
          bottomNavigationBar: const AppBottomNav(currentIndex: 3),
        );
      },
    );
  }
}

BoxDecoration _cardDecoration(BuildContext context) {
  final ScootColors c = ScootColors.of(context);
  return BoxDecoration(
    color: c.card,
    border: Border.all(color: c.line),
    borderRadius: ScootRadius.cardAll,
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: ScootType.section.copyWith(color: ScootColors.of(context).ink),
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  final UserModel user;
  const _ProfileHeader({required this.user});

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: _cardDecoration(context),
        child: Row(
          children: [
            _Avatar(user: user),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.name,
                    style: ScootType.cardTitle.copyWith(color: c.ink),
                  ),
                  Text(
                    <String>[
                      editProfileRoleLabel(user.role),
                      if (user.staffId.isNotEmpty) user.staffId,
                    ].join(' · '),
                    style: ScootType.small.copyWith(color: c.text2),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      _Chip(label: user.territory, tone: ScootTone.neutral),
                      _Chip(
                        label: user.isActive ? 'Active' : 'Inactive',
                        tone: user.isActive
                            ? ScootTone.success
                            : ScootTone.neutral,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final UserModel user;
  const _Avatar({required this.user});

  void _showFullScreenImage(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.zero,
          child: Stack(
            children: [
              Container(
                color: Colors.black.withValues(alpha: 0.95),
                width: double.infinity,
                height: double.infinity,
                child: Center(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4.0,
                    child: user.photoUrl.isNotEmpty
                        ? buildProfileImage(
                            user.photoUrl,
                            width: MediaQuery.of(context).size.width * 0.9,
                            height: MediaQuery.of(context).size.width * 0.9,
                            fallback: _initialsFallback(fullscreen: true),
                          )
                        : _initialsFallback(fullscreen: true),
                  ),
                ),
              ),
              Positioned(
                top: 40,
                right: 20,
                child: Material(
                  color: Colors.white.withValues(alpha: 0.2),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => Navigator.pop(context),
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.close, color: Colors.white, size: 28),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showFullScreenImage(context),
      child: Container(
        width: 64,
        height: 64,
        decoration: const BoxDecoration(shape: BoxShape.circle),
        child: ClipOval(
          child: user.photoUrl.isNotEmpty
              ? buildProfileImage(
                  user.photoUrl,
                  width: 64,
                  height: 64,
                  fallback: _initialsFallback(),
                )
              : _initialsFallback(),
        ),
      ),
    );
  }

  Widget _initialsFallback({bool fullscreen = false}) {
    return Container(
      color: const Color(0xFF1F4F40),
      child: Center(
        child: Text(
          user.effectiveInitials,
          style: TextStyle(
            color: Colors.white,
            fontSize: fullscreen ? 80 : 24,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final ScootTone tone;
  const _Chip({required this.label, required this.tone});

  @override
  Widget build(BuildContext context) {
    final ScootToneColors t = ScootColors.of(context).tone(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: t.background,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: ScootType.small.copyWith(color: t.foreground)),
    );
  }
}

class _QuickAccessSection extends StatelessWidget {
  const _QuickAccessSection();

  void _navigateToWeeklyPlanner(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PlannerScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Quick access'),
          Container(
            decoration: _cardDecoration(context),
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    ScootIcons.calendar,
                    color: ScootColors.of(context).brandText,
                  ),
                  title: const Text(
                    'Weekly Planner',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  subtitle: const Text('Plan your route visits'),
                  trailing: Icon(
                    ScootIcons.chevronRight,
                    color: ScootColors.of(context).text2,
                  ),
                  onTap: () => _navigateToWeeklyPlanner(context),
                ),
                if (context.watch<AuthProvider>().user?.hasSalespersonRole ==
                    true)
                  ListTile(
                    leading: Icon(
                      ScootIcons.history,
                      color: ScootColors.of(context).brandText,
                    ),
                    title: const Text('My visits'),
                    subtitle: const Text('View your visit history'),
                    trailing: Icon(
                      ScootIcons.chevronRight,
                      color: ScootColors.of(context).text2,
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const MyVisitsScreen()),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountSection extends StatelessWidget {
  final UserModel user;
  const _AccountSection({required this.user});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Account'),
          Container(
            decoration: _cardDecoration(context),
            child: Column(
              children: [
                _InfoRow(label: 'Staff ID', value: user.staffId),
                const _Divider(),
                _InfoRow(label: 'Email', value: user.email),
                const _Divider(),
                _InfoRow(
                  label: 'Phone',
                  value: user.phone.isEmpty ? 'Not set' : user.phone,
                  isLink: user.phone.isNotEmpty,
                ),
                const _Divider(),
                _InfoRow(label: 'Territory', value: user.territory),
                if (user.joinedDate.isNotEmpty) ...[
                  const _Divider(),
                  _InfoRow(label: 'Joined', value: user.joinedDate),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isLink;
  const _InfoRow({
    required this.label,
    required this.value,
    this.isLink = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Color(0xFF888888)),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isLink
                    ? ScootColors.of(context).brandText
                    : ScootColors.of(context).ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.only(left: 16),
      color: ScootColors.of(context).line,
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final UserModel user;
  const _SettingsSection({required this.user});

  Future<void> _saveLocationSharing(BuildContext context, bool enabled) async {
    final messenger = ScaffoldMessenger.of(context);
    final AuthProvider auth = context.read<AuthProvider>();
    final GpsProvider gps = context.read<GpsProvider>();
    final bool previous = auth.user?.gpsAutofill ?? true;
    if (!enabled) await gps.setTrackingEnabled(false);
    try {
      await auth.updateSettings(user.uid, {'gpsAutofill': enabled});
    } catch (e) {
      await gps.setTrackingEnabled(previous);
      if (previous) {
        await gps.startTracking(user: user, explicit: true);
      }
      final String msg = e.toString().replaceFirst('Exception: ', '');
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text("Couldn't save Location sharing: $msg"),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }
    if (enabled) {
      await gps.setTrackingEnabled(true);
      try {
        await gps.startTracking(user: auth.user ?? user, explicit: true);
      } catch (_) {}
    }
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Location sharing saved'),
        backgroundColor: Color(0xFF2D6A4F),
        behavior: SnackBarBehavior.floating,
        duration: Duration(milliseconds: 1200),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Settings'),
          Container(
            decoration: _cardDecoration(context),
            child: Column(
              children: [
                _SettingToggle(
                  title: 'Location sharing',
                  subtitle:
                      'Use GPS for verified arrivals and live route status',
                  value: user.gpsAutofill,
                  onChanged: (v) => _saveLocationSharing(context, v),
                ),
                const _Divider(),
                const _LegalRow(
                  icon: ScootIcons.privacy,
                  title: 'Privacy Policy',
                  kind: LegalDocumentKind.privacyPolicy,
                ),
                const _Divider(),
                const _LegalRow(
                  icon: ScootIcons.document,
                  title: 'Terms',
                  kind: LegalDocumentKind.termsAndConditions,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LegalRow extends StatelessWidget {
  const _LegalRow({
    required this.icon,
    required this.title,
    required this.kind,
  });

  final IconData icon;
  final String title;
  final LegalDocumentKind kind;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: ScootColors.of(context).brandText),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
      trailing: Icon(
        ScootIcons.chevronRight,
        color: ScootColors.of(context).text2,
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => LegalDocumentScreen(kind: kind),
        ),
      ),
    );
  }
}

class _WorkSessionSection extends StatefulWidget {
  const _WorkSessionSection({required this.user});

  final UserModel user;

  @override
  State<_WorkSessionSection> createState() => _WorkSessionSectionState();
}

class _WorkSessionSectionState extends State<_WorkSessionSection> {
  bool _busy = false;

  Future<void> _toggle(GpsProvider gps) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (gps.hasAcknowledgedWorkSession &&
          gps.workSession?.uid == widget.user.uid) {
        await gps.endWork(uid: widget.user.uid);
      } else if (widget.user.gpsAutofill) {
        await gps.setTrackingEnabled(true);
        await gps.startTracking(user: widget.user, explicit: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<GpsProvider>(
      builder: (BuildContext context, GpsProvider gps, _) {
        final bool active =
            gps.hasAcknowledgedWorkSession &&
            gps.workSession?.uid == widget.user.uid;
        final bool sharingEnabled = widget.user.gpsAutofill;
        final String status = !sharingEnabled
            ? 'Location sharing is disabled in Settings.'
            : gps.statusMessage;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: _cardDecoration(context),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Work session',
                  style: ScootType.section.copyWith(
                    color: ScootColors.of(context).ink,
                  ),
                ),
                const SizedBox(height: 6),
                Text(status, style: const TextStyle(fontSize: 13)),
                if (gps.workSessionNeedsSync) ...<Widget>[
                  const SizedBox(height: 4),
                  const Text(
                    'The latest session change has not reached the server.',
                    style: TextStyle(fontSize: 12, color: Colors.deepOrange),
                  ),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _busy || !sharingEnabled
                        ? null
                        : () => _toggle(gps),
                    child: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(active ? 'End Work' : 'Start Work'),
                  ),
                ),
                if (!sharingEnabled)
                  const Text(
                    'Turn on Location sharing below to start Work.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF666666)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SettingToggle extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingToggle({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF888888),
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _SignOutButton extends StatefulWidget {
  @override
  State<_SignOutButton> createState() => _SignOutButtonState();
}

class _SignOutButtonState extends State<_SignOutButton> {
  bool _checkingWork = false;

  Future<bool> _hasWorkWhileBusy(HeldWorkSync sync, String uid) async {
    if (mounted) setState(() => _checkingWork = true);
    try {
      return uid.isNotEmpty && await sync.hasWorkToUpload(uid);
    } finally {
      if (mounted) setState(() => _checkingWork = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color foreground = ScootColors.of(context).danger.foreground;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        width: double.infinity,
        height: 54,
        child: ElevatedButton(
          onPressed: () async {
            if (_checkingWork) return;
            final String uid = context.read<AuthProvider>().user?.uid ?? '';
            final HeldWorkSync sync = HeldWorkSync();
            final bool confirmed = await confirmSignOut(
              context,
              hasWork: () => _hasWorkWhileBusy(sync, uid),
              upload: uploadWaitingWork,
            );
            if (!confirmed || !context.mounted) return;

            final gpsProvider = context.read<GpsProvider>();
            final authProvider = context.read<AuthProvider>();
            final navigator = Navigator.of(context);
            try {
              await gpsProvider
                  .endWork(uid: authProvider.user?.uid)
                  .timeout(const Duration(seconds: 6));
            } catch (_) {}
            await authProvider.logout();
            if (!navigator.mounted) return;
            navigator.popUntil((route) => route.isFirst);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: ScootColors.of(context).danger.background,
            foregroundColor: foreground,
            elevation: 0,
            side: BorderSide(color: ScootColors.of(context).danger.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_checkingWork) ...[
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: foreground,
                  ),
                ),
                const SizedBox(width: 12),
              ],
              const Text('Sign Out'),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeleteAccountRow extends StatelessWidget {
  const _DeleteAccountRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => const DeleteAccountScreen(),
          ),
        ),
        style: TextButton.styleFrom(
          foregroundColor: ScootColors.of(context).danger.foreground,
          minimumSize: const Size(48, 48),
        ),
        child: const Text('Delete account'),
      ),
    );
  }
}
