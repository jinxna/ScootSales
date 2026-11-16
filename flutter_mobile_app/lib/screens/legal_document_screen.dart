import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:scoot_legal/scoot_legal.dart';

export 'package:scoot_legal/scoot_legal.dart' show LegalDocumentKind;

class LegalDocumentLinks extends StatelessWidget {
  const LegalDocumentLinks({super.key});

  Widget _link(BuildContext context, LegalDocumentKind kind) => TextButton(
    style: TextButton.styleFrom(
      minimumSize: const Size(ScootSize.phoneTarget, ScootSize.phoneTarget),
    ),
    onPressed: () => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => LegalDocumentScreen(kind: kind)),
    ),
    child: Text(legalTitle(kind)),
  );

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      children: <Widget>[
        _link(context, LegalDocumentKind.privacyPolicy),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Text('·'),
        ),
        _link(context, LegalDocumentKind.termsAndConditions),
      ],
    );
  }
}

class LegalDocumentScreen extends StatelessWidget {
  const LegalDocumentScreen({super.key, required this.kind});

  final LegalDocumentKind kind;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ScootColors.of(context).page,
      appBar: ScootPhoneAppBar(
        title: legalTitle(kind),
        onBack: () => Navigator.of(context).maybePop(),
      ),
      body: LegalDocumentView(
        document: kind,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      ),
    );
  }
}
