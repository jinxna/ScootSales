import 'dart:convert';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import 'package:scoot_design/scoot_design.dart';
import '../theme/app_theme.dart';
import '../widgets/phone_card.dart';

Widget buildProfileImage(
  String photoUrl, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.cover,
  Widget? fallback,
}) {
  if (photoUrl.isEmpty) {
    return fallback ?? const SizedBox();
  }
  if (photoUrl.startsWith('data:image')) {
    try {
      final base64Part = photoUrl.split(',').last;
      final bytes = base64Decode(base64Part);
      return Image.memory(bytes, width: width, height: height, fit: fit);
    } catch (_) {
      return fallback ?? const SizedBox();
    }
  }
  return Image.network(
    photoUrl,
    width: width,
    height: height,
    fit: fit,
    errorBuilder: (_, _, _) => fallback ?? const SizedBox(),
  );
}

class EditProfileScreen extends StatefulWidget {
  final UserModel user;
  const EditProfileScreen({super.key, required this.user});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  static const Color headerGreen = Color(0xFF3A7D5C);

  late final TextEditingController _nameCtrl;
  late final TextEditingController _displayCtrl;

  Uint8List? _newPhotoBytes;
  String _newPhotoExt = 'jpg';
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    _nameCtrl = TextEditingController(text: u.name);
    _displayCtrl = TextEditingController(text: u.effectiveDisplayName);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _displayCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Change Profile Photo',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: headerGreen),
              title: const Text('Take Photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: headerGreen),
              title: const Text('Choose from Gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.close, color: headerGreen),
              title: const Text('Cancel'),
              onTap: () => Navigator.pop(context),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (source == null) return;

    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        maxWidth: 400,
        maxHeight: 400,
        imageQuality: 70,
      );
      if (picked != null) {
        final bytes = await picked.readAsBytes();
        final name = picked.name.toLowerCase();
        final ext = name.contains('.') ? name.split('.').last : 'jpg';
        setState(() {
          _newPhotoBytes = bytes;
          _newPhotoExt = ext;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the photo. Try again.')),
      );
    }
  }

  Future<void> _save() async {
    if (_isSaving) return;

    if (_nameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Full name is required')));
      return;
    }

    setState(() => _isSaving = true);

    final auth = context.read<AuthProvider>();
    try {
      await auth.updateProfile(
        uid: widget.user.uid,
        name: _nameCtrl.text.trim(),
        displayName: _displayCtrl.text.trim(),
        initials: widget.user.effectiveInitials,
        email: widget.user.email,
        phone: widget.user.phone,
        territory: widget.user.territory,
        role: widget.user.role,
        photoBytes: _newPhotoBytes,
        photoExt: _newPhotoExt,
      );
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Profile updated successfully'),
          backgroundColor: Colors.green.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      final msg = e.toString().replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed: $msg'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  void _showChangePhoneDialog() {
    final passwordCtrl = TextEditingController();
    final phoneCtrl = TextEditingController(text: widget.user.phone);
    bool saving = false;
    String? errorText;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          icon: const Icon(Icons.phone_outlined, size: 36, color: headerGreen),
          title: const Text(
            'Change Phone Number',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter your current password to verify your identity, then set your new phone number.',
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF555555),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: 'New Phone Number',
                  prefixIcon: const Icon(Icons.phone_outlined, size: 18),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Current Password',
                  prefixIcon: const Icon(Icons.lock_outline, size: 18),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  errorText: errorText,
                ),
              ),
            ],
          ),
          actions: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: headerGreen),
                    onPressed: saving
                        ? null
                        : () async {
                            final phone = phoneCtrl.text.trim();
                            final password = passwordCtrl.text;
                            if (phone.isEmpty || password.isEmpty) {
                              setDialogState(
                                () => errorText = 'All fields are required.',
                              );
                              return;
                            }
                            setDialogState(() {
                              saving = true;
                              errorText = null;
                            });
                            try {
                              final auth = context.read<AuthProvider>();
                              await auth.updatePhoneWithVerification(
                                uid: widget.user.uid,
                                currentPassword: password,
                                newPhone: phone,
                              );
                              if (ctx.mounted) Navigator.pop(ctx);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: const Text(
                                      'Phone number updated successfully.',
                                    ),
                                    backgroundColor: Colors.green.shade700,
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                                Navigator.pop(context);
                              }
                            } on FirebaseAuthException catch (e) {
                              setDialogState(() {
                                saving = false;
                                errorText = e.code == 'wrong-password'
                                    ? 'Incorrect password. Please try again.'
                                    : e.message ?? 'Verification failed.';
                              });
                            } catch (e) {
                              setDialogState(() {
                                saving = false;
                                errorText = e.toString().replaceFirst(
                                  'Exception: ',
                                  '',
                                );
                              });
                            }
                          },
                    child: saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text('Verify & Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showChangeEmailDialog() {
    final passwordCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    bool saving = false;
    String? errorText;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          icon: const Icon(Icons.email_outlined, size: 36, color: headerGreen),
          title: const Text(
            'Change Email Address',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade200),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Colors.amber.shade700,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'A verification link will be sent to your new email. You must click it to confirm the change.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textAmber,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'New Email Address',
                  prefixIcon: const Icon(Icons.email_outlined, size: 18),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Current Password',
                  prefixIcon: const Icon(Icons.lock_outline, size: 18),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  errorText: errorText,
                ),
              ),
            ],
          ),
          actions: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: headerGreen),
                    onPressed: saving
                        ? null
                        : () async {
                            final newEmail = emailCtrl.text.trim();
                            final password = passwordCtrl.text;
                            if (newEmail.isEmpty || password.isEmpty) {
                              setDialogState(
                                () => errorText = 'All fields are required.',
                              );
                              return;
                            }
                            setDialogState(() {
                              saving = true;
                              errorText = null;
                            });
                            try {
                              final auth = context.read<AuthProvider>();
                              await auth.changeEmailWithVerification(
                                currentPassword: password,
                                newEmail: newEmail,
                              );
                              if (ctx.mounted) Navigator.pop(ctx);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Verification email sent to $newEmail. Click the link to confirm.',
                                    ),
                                    backgroundColor: Colors.green.shade700,
                                    behavior: SnackBarBehavior.floating,
                                    duration: const Duration(seconds: 6),
                                  ),
                                );
                              }
                            } on FirebaseAuthException catch (e) {
                              setDialogState(() {
                                saving = false;
                                errorText = e.code == 'wrong-password'
                                    ? 'Incorrect password. Please try again.'
                                    : e.message ?? 'Verification failed.';
                              });
                            } catch (e) {
                              setDialogState(() {
                                saving = false;
                                errorText = e.toString().replaceFirst(
                                  'Exception: ',
                                  '',
                                );
                              });
                            }
                          },
                    child: saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text('Send link'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool get _dirty =>
      _newPhotoBytes != null ||
      _nameCtrl.text.trim() != widget.user.name.trim() ||
      _displayCtrl.text.trim() != widget.user.effectiveDisplayName.trim();

  Future<bool> _confirmDiscard() async {
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your changes are not saved.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final bool dirty = _dirty;
    return PopScope(
      canPop: !dirty || _isSaving,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;
        final NavigatorState navigator = Navigator.of(context);
        if (await _confirmDiscard()) navigator.pop();
      },
      child: ScootPhoneScaffold(
        appBar: ScootPhoneAppBar(
          title: 'Edit profile',
          onBack: () => Navigator.of(context).maybePop(),
        ),
        body: ListView(
          padding: const EdgeInsets.all(ScootSpace.phoneGutter),
          children: <Widget>[
            Center(child: _avatarBlock(c)),
            const SizedBox(height: 16),
            PhoneCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _fieldLabel('Full name', c),
                  TextField(
                    controller: _nameCtrl,
                    textCapitalization: TextCapitalization.words,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  _fieldLabel('Display name', c),
                  TextField(
                    controller: _displayCtrl,
                    onChanged: (_) => setState(() {}),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'The short name your team sees.',
                      style: ScootType.small.copyWith(color: c.muted),
                    ),
                  ),
                ],
              ),
            ),
            const PhoneSectionTitle('Contact'),
            PhoneCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: <Widget>[
                  _contactRow(
                    label: 'Email',
                    value: widget.user.email,
                    action: 'Change',
                    onPressed: _showChangeEmailDialog,
                    c: c,
                  ),
                  const PhoneDivider(),
                  _contactRow(
                    label: 'Phone',
                    value: widget.user.phone.isEmpty
                        ? 'Not set'
                        : widget.user.phone,
                    action: widget.user.phone.isEmpty ? 'Add' : 'Change',
                    onPressed: _showChangePhoneDialog,
                    c: c,
                  ),
                ],
              ),
            ),
            const PhoneSectionTitle('Set by your admin'),
            PhoneCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: <Widget>[
                  if (widget.user.staffId.isNotEmpty) ...<Widget>[
                    PhoneRow(label: 'Staff ID', value: widget.user.staffId),
                    const PhoneDivider(),
                  ],
                  if (widget.user.territory.isNotEmpty) ...<Widget>[
                    PhoneRow(label: 'Territory', value: widget.user.territory),
                    const PhoneDivider(),
                  ],
                  PhoneRow(
                    label: 'Role',
                    value: editProfileRoleLabel(widget.user.role),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Row(
                children: <Widget>[
                  Icon(ScootIcons.lock, size: 14, color: c.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Ask your manager to change these.',
                      style: ScootType.small.copyWith(color: c.muted),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        primaryAction: ScootPrimaryActionBar(
          label: _isSaving ? 'Saving...' : 'Save changes',
          onPressed: _isSaving || !dirty ? null : _save,
          disabledReason: _isSaving ? null : 'Nothing changed yet.',
        ),
      ),
    );
  }

  Widget _fieldLabel(String text, ScootColors c) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: ScootType.smallStrong.copyWith(color: c.text2)),
  );

  Widget _contactRow({
    required String label,
    required String value,
    required String action,
    required VoidCallback onPressed,
    required ScootColors c,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(label, style: ScootType.small.copyWith(color: c.text2)),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ScootType.bodyStrong.copyWith(color: c.ink),
            ),
          ),
          TextButton(onPressed: onPressed, child: Text(action)),
        ],
      ),
    );
  }

  Widget _avatarBlock(ScootColors c) {
    return Column(
      children: <Widget>[
        GestureDetector(onTap: _pickPhoto, child: _avatarPreview()),
        TextButton(onPressed: _pickPhoto, child: const Text('Change photo')),
        if (_newPhotoBytes != null)
          Text(
            'Not saved yet',
            style: ScootType.small.copyWith(color: c.warning.noteText),
          ),
      ],
    );
  }

  Widget _avatarPreview() {
    final initials = widget.user.effectiveInitials;

    Widget avatarChild;
    if (_newPhotoBytes != null) {
      avatarChild = ClipOval(
        child: Image.memory(
          _newPhotoBytes!,
          width: 80,
          height: 80,
          fit: BoxFit.cover,
        ),
      );
    } else if (widget.user.photoUrl.isNotEmpty) {
      avatarChild = ClipOval(
        child: buildProfileImage(
          widget.user.photoUrl,
          width: 80,
          height: 80,
          fallback: _initialsAvatar(initials),
        ),
      );
    } else {
      avatarChild = _initialsAvatar(initials);
    }
    return SizedBox.square(dimension: 80, child: avatarChild);
  }

  Widget _initialsAvatar(String initials) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(color: c.brandText, shape: BoxShape.circle),
      child: Center(
        child: Text(
          initials,
          style: ScootType.h1.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

String editProfileRoleLabel(String role) {
  final String r = role.trim().toLowerCase();
  if (r == 'salesman' || r == 'salesperson') return 'Salesperson';
  if (r.isEmpty) return 'Not set';
  return r[0].toUpperCase() + r.substring(1);
}
