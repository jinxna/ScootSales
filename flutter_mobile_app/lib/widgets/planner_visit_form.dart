import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputFormatter;
import 'package:scoot_design/scoot_design.dart';

import 'phone_card.dart';

class PlannerVisitForm extends StatelessWidget {
  const PlannerVisitForm({
    super.key,
    required this.isEditing,
    required this.dateLabel,
    required this.dayName,
    required this.timeLabel,
    required this.marketplaces,
    required this.selectedMarketplace,
    required this.purposeController,
    required this.notesController,
    required this.purposeFormatters,
    required this.notesFormatters,
    required this.saving,
    required this.onBack,
    required this.onPickDate,
    required this.onPickTime,
    required this.onMarketplaceChanged,
    required this.onPurposeChanged,
    required this.onNotesChanged,
    required this.onSave,
    this.formError,
    this.retailerLoadError,
  });

  final bool isEditing;
  final String? dateLabel;
  final String? dayName;
  final String timeLabel;
  final List<String> marketplaces;
  final String? selectedMarketplace;
  final TextEditingController purposeController;
  final TextEditingController notesController;
  final List<TextInputFormatter> purposeFormatters;
  final List<TextInputFormatter> notesFormatters;
  final bool saving;
  final String? formError;
  final String? retailerLoadError;
  final VoidCallback onBack;
  final VoidCallback onPickDate;
  final VoidCallback onPickTime;
  final ValueChanged<String?> onMarketplaceChanged;
  final ValueChanged<String> onPurposeChanged;
  final ValueChanged<String> onNotesChanged;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return ScootPhoneScaffold(
      appBar: ScootPhoneAppBar(
        title: isEditing ? 'Edit visit' : 'New visit plan',
        onBack: onBack,
      ),
      body: ListView(
        padding: const EdgeInsets.all(ScootSpace.phoneGutter),
        children: <Widget>[
          if (formError != null) ...<Widget>[
            ScootNotice(
              tone: ScootTone.danger,
              icon: ScootIcons.warning,
              message: formError!,
              liveRegion: true,
            ),
            const SizedBox(height: 12),
          ],
          PhoneCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _label('Date', c),
                _pickerTile(
                  c,
                  icon: ScootIcons.calendar,
                  title: dateLabel ?? 'Choose a date',
                  subtitle: dayName,
                  placeholder: dateLabel == null,
                  onTap: onPickDate,
                ),
                const SizedBox(height: 16),
                _label('Time', c),
                _pickerTile(
                  c,
                  icon: ScootIcons.clock,
                  title: timeLabel,
                  onTap: onPickTime,
                ),
              ],
            ),
          ),
          const PhoneSectionTitle('Retailer'),
          PhoneCard(
            child: marketplaces.isEmpty
                ? Text(
                    retailerLoadError ??
                        'No retailers are assigned to you yet. Ask your admin '
                            'to assign retailers to you, then open this plan '
                            'again.',
                    style: ScootType.body.copyWith(color: c.text2),
                  )
                : DropdownButtonFormField<String>(
                    initialValue: marketplaces.contains(selectedMarketplace)
                        ? selectedMarketplace
                        : null,
                    isExpanded: true,
                    hint: const Text('Choose a retailer'),
                    items: <DropdownMenuItem<String>>[
                      for (final String name in marketplaces)
                        DropdownMenuItem<String>(
                          value: name,
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: onMarketplaceChanged,
                  ),
          ),
          const PhoneSectionTitle('Details'),
          PhoneCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _label('Purpose of visit', c),
                TextField(
                  controller: purposeController,
                  maxLength: 200,
                  inputFormatters: purposeFormatters,
                  smartQuotesType: SmartQuotesType.disabled,
                  smartDashesType: SmartDashesType.disabled,
                  onChanged: onPurposeChanged,
                  decoration: const InputDecoration(
                    hintText: 'For example, restock check',
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 16),
                _label('Notes (optional)', c),
                TextField(
                  controller: notesController,
                  maxLines: 3,
                  maxLength: 500,
                  inputFormatters: notesFormatters,
                  smartQuotesType: SmartQuotesType.disabled,
                  smartDashesType: SmartDashesType.disabled,
                  onChanged: onNotesChanged,
                  decoration: const InputDecoration(
                    hintText: 'Anything to remember',
                    counterText: '',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      primaryAction: ScootPrimaryActionBar(
        label: saving
            ? 'Saving...'
            : isEditing
            ? 'Update visit'
            : 'Save plan',
        onPressed: saving ? null : onSave,
      ),
    );
  }

  Widget _label(String text, ScootColors c) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: ScootType.smallStrong.copyWith(color: c.text2)),
  );

  Widget _pickerTile(
    ScootColors c, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    String? subtitle,
    bool placeholder = false,
  }) {
    return ScootPressable(
      onTap: onTap,
      minSize: const Size(48, 48),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ScootType.bodyStrong.copyWith(
                      color: placeholder ? c.muted : c.ink,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: ScootType.small.copyWith(color: c.muted),
                    ),
                ],
              ),
            ),
            Icon(icon, size: 20, color: c.brandText),
          ],
        ),
      ),
    );
  }
}
