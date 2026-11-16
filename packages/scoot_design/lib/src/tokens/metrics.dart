import 'package:flutter/widgets.dart';

class ScootType {
  const ScootType._();

  static const String fontFamily = 'packages/scoot_design/Inter';
  static const List<String> fontFamilyFallback = <String>[
    'Segoe UI',
    'system-ui',
    'sans-serif',
  ];
  static const String monoFamily = 'packages/scoot_design/JetBrains Mono';
  static const List<String> monoFamilyFallback = <String>[
    'Roboto Mono',
    'Consolas',
    'Menlo',
    'monospace',
  ];
  static const List<FontFeature> tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  static const TextStyle h1 = TextStyle(
    fontSize: 24,
    height: 1.25,
    fontWeight: FontWeight.w700,
  );
  static const TextStyle h2 = TextStyle(
    fontSize: 18,
    height: 1.3,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle cardTitle = TextStyle(
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle section = TextStyle(
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle body = TextStyle(
    fontSize: 14,
    height: 1.45,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle bodyStrong = TextStyle(
    fontSize: 14,
    height: 1.45,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle small = TextStyle(
    fontSize: 13,
    height: 1.4,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle smallStrong = TextStyle(
    fontSize: 13,
    height: 1.4,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    height: 1.35,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle tableHead = TextStyle(
    fontSize: 12,
    height: 1.35,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle navLabel = TextStyle(
    fontSize: 11,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.88,
  );
  static const TextStyle button = TextStyle(
    fontSize: 14,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle kpi = TextStyle(
    fontSize: 28,
    height: 1.2,
    fontWeight: FontWeight.w700,
    fontFeatures: tabular,
  );
  static const TextStyle number = TextStyle(
    fontSize: 14,
    height: 1.45,
    fontFeatures: tabular,
  );
  static const TextStyle mono = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFamilyFallback,
    fontSize: 13,
    height: 1.4,
    fontFeatures: tabular,
  );

  static const TextStyle phoneTitle = TextStyle(
    fontSize: 18,
    height: 1.25,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle phoneSubpageTitle = TextStyle(
    fontSize: 17,
    height: 1.25,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle phoneButton = TextStyle(
    fontSize: 16,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle phoneNav = TextStyle(
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w500,
  );
}

class ScootSpace {
  const ScootSpace._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double blockGap = 18;
  static const double phoneGutter = 16;
  static const EdgeInsets dashboardMain = EdgeInsets.fromLTRB(32, 24, 32, 32);
  static const EdgeInsets cardHeader = EdgeInsets.symmetric(
    horizontal: 20,
    vertical: 16,
  );
  static const EdgeInsets cardBody = EdgeInsets.symmetric(
    horizontal: 20,
    vertical: 16,
  );
  static const EdgeInsets tableCell = EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 12,
  );
}

class ScootRadius {
  const ScootRadius._();

  static const double control = 8;
  static const double note = 10;
  static const double card = 12;
  static const double sheet = 16;
  static const double pill = 999;

  static const BorderRadius controlAll = BorderRadius.all(
    Radius.circular(control),
  );
  static const BorderRadius noteAll = BorderRadius.all(Radius.circular(note));
  static const BorderRadius cardAll = BorderRadius.all(Radius.circular(card));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
  static const BorderRadius sheetTop = BorderRadius.vertical(
    top: Radius.circular(sheet),
  );
}

class ScootElevation {
  const ScootElevation._();

  static const List<BoxShadow> none = <BoxShadow>[];
  static const List<BoxShadow> raised = <BoxShadow>[
    BoxShadow(color: Color(0x1A10231A), blurRadius: 14, offset: Offset(0, 4)),
  ];
  static const List<BoxShadow> drawer = <BoxShadow>[
    BoxShadow(color: Color(0x2910231A), blurRadius: 32, offset: Offset(-12, 0)),
  ];
  static const List<BoxShadow> overlay = <BoxShadow>[
    BoxShadow(color: Color(0x4710231A), blurRadius: 60, offset: Offset(0, 24)),
  ];
}

class ScootSize {
  const ScootSize._();

  static const double dashboardTarget = 40;
  static const double phoneTarget = 44;
  static const double control = 40;
  static const double rail = 236;
  static const double topBar = 64;
  static const double searchMaxWidth = 520;
  static const double scopePill = 32;
  static const double avatar = 34;
  static const double drawer = 620;
  static const double tableRow = 48;
  static const double tableHeader = 40;
  static const double icon = 18;
  static const double phoneIcon = 22;
  static const double phoneAppBar = 56;
  static const double statusStrip = 44;
  static const double stepBar = 44;
  static const double bottomNav = 64;
  static const double homeIndicator = 20;
  static const double primaryButton = 48;
  static const double copilotPill = 36;
  static const double gpsChip = 28;
  static const Size dashboardFrame = Size(1440, 900);
  static const Size phoneFrame = Size(390, 844);
}

class ScootTiming {
  const ScootTiming._();

  static const Duration stillLoadingAfter = Duration(seconds: 10);
  static const Duration countRefresh = Duration(seconds: 60);
  static const Duration fast = Duration(milliseconds: 120);
}

class ScootPaging {
  const ScootPaging._();

  static const int pageSize = 50;
}
