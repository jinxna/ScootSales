import 'package:flutter/material.dart';

import 'legal_text.dart';

class LegalDocumentView extends StatefulWidget {
  const LegalDocumentView({
    super.key,
    required this.document,
    this.padding = const EdgeInsets.all(24),
  });

  final LegalDocumentKind document;
  final EdgeInsetsGeometry padding;

  @override
  State<LegalDocumentView> createState() => _LegalDocumentViewState();
}

class _LegalDocumentViewState extends State<LegalDocumentView> {
  static const double _indexBreakpoint = 900;
  static const double _textWidth = 720;

  LegalLanguage _language = LegalLanguage.english;
  List<GlobalKey> _sectionKeys = <GlobalKey>[];

  Widget _languageButton(LegalLanguage language) {
    void choose() => setState(() => _language = language);
    final Widget label = Text(language.label);
    return language == _language
        ? FilledButton.tonal(onPressed: choose, child: label)
        : OutlinedButton(onPressed: choose, child: label);
  }

  void _jumpTo(int index) {
    final BuildContext? target = _sectionKeys[index].currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 150),
      );
    }
  }

  Widget _statusBadge(ThemeData theme, String status) {
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: scheme.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              status,
              style: TextStyle(
                color: scheme.onTertiaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionIndex(ThemeData theme, LegalText text) {
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int i = 0; i < text.sections.length; i++)
            InkWell(
              onTap: () => _jumpTo(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  text.sections[i].heading,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme, LegalText text) {
    final ColorScheme scheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _textWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              text.title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            text.versionLine,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          _statusBadge(theme, text.status),
          const SizedBox(height: 24),
          for (int i = 0; i < text.sections.length; i++) ...<Widget>[
            Semantics(
              header: true,
              child: Text(
                text.sections[i].heading,
                key: _sectionKeys[i],
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(text.sections[i].body, style: const TextStyle(height: 1.5)),
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final LegalText text = legalText(widget.document, _language);
    if (_sectionKeys.length != text.sections.length) {
      _sectionKeys = List<GlobalKey>.generate(
        text.sections.length,
        (_) => GlobalKey(),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool withIndex = constraints.maxWidth >= _indexBreakpoint;
        return SingleChildScrollView(
          padding: widget.padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final LegalLanguage language in LegalLanguage.values)
                    _languageButton(language),
                ],
              ),
              const SizedBox(height: 20),
              if (withIndex)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _sectionIndex(theme, text),
                    const SizedBox(width: 32),
                    Flexible(child: _body(theme, text)),
                  ],
                )
              else
                _body(theme, text),
            ],
          ),
        );
      },
    );
  }
}
