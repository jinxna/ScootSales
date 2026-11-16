import 'package:flutter/material.dart';
import 'package:scoot_legal/scoot_legal.dart';

export 'package:scoot_legal/scoot_legal.dart' show LegalDocumentKind;

class LegalDocumentPage extends StatelessWidget {
  const LegalDocumentPage({
    super.key,
    required this.document,
    this.embedded = false,
  });

  final LegalDocumentKind document;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final Widget body = LegalDocumentView(document: document);
    return embedded
        ? body
        : Scaffold(
            appBar: AppBar(title: Text(legalTitle(document))),
            body: body,
          );
  }
}

Future<void> showLegalDocument(
  BuildContext context,
  LegalDocumentKind document,
) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 720,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: LegalDocumentPage(document: document, embedded: true),
      ),
    ),
  );
}
