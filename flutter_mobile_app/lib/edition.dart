const String kEdition = String.fromEnvironment(
  'EDITION',
  defaultValue: 'advanced',
);

const Set<String> _knownEditions = <String>{'basic', 'advanced'};

const bool kBasicEdition = kEdition == 'basic';

String? get editionError => _knownEditions.contains(kEdition)
    ? null
    : 'This build has an unknown EDITION "$kEdition". '
          'Rebuild it with EDITION=basic or EDITION=advanced.';

const String kNotInEditionMessage =
    'Visit briefs are not part of this edition of the app.';
