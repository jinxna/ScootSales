import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

Future<T?> chooseBarcodeProduct<T>(
  BuildContext context, {
  required List<T> matches,
  required String Function(T) label,
}) async {
  if (matches.isEmpty) return null;
  if (matches.length == 1) return matches.single;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) =>
        BarcodeProductChoiceSheet<T>(matches: matches, label: label),
  );
}

class BarcodeProductChoiceSheet<T> extends StatelessWidget {
  const BarcodeProductChoiceSheet({
    super.key,
    required this.matches,
    required this.label,
  });

  final List<T> matches;
  final String Function(T) label;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ScootSpace.phoneGutter,
              0,
              ScootSpace.phoneGutter,
              8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Choose scanned product',
                  style: ScootType.h2.copyWith(color: c.ink),
                ),
                const SizedBox(height: 4),
                Text(
                  'Several products share this barcode. Choose the exact product.',
                  style: ScootType.body.copyWith(color: c.text2),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(
                horizontal: ScootSpace.phoneGutter,
              ),
              itemCount: matches.length,
              separatorBuilder: (_, _) => Divider(height: 1, color: c.line),
              itemBuilder: (BuildContext context, int index) {
                final T product = matches[index];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  minVerticalPadding: 12,
                  title: Text(
                    label(product),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: ScootType.bodyStrong.copyWith(color: c.ink),
                  ),
                  trailing: const ScootBadge(
                    label: 'Add',
                    tone: ScootTone.success,
                  ),
                  onTap: () => Navigator.of(context).pop(product),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(ScootSpace.phoneGutter),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(ScootSize.primaryButton),
              ),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ),
        ],
      ),
    );
  }
}
