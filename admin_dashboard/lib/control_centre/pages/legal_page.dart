import 'package:flutter/material.dart';
import 'package:scoot_legal/scoot_legal.dart';

export 'package:scoot_legal/scoot_legal.dart' show LegalDocumentKind;

class ControlCentreLegalPage extends StatelessWidget {
  const ControlCentreLegalPage({super.key, required this.document});

  final LegalDocumentKind document;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(legalTitle(document))),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: LegalDocumentView(document: document),
      ),
    ),
  );
}
