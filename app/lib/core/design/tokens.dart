import 'package:flutter/widgets.dart';

/// Colour tokens — mirrors the `variables` block of `crazycut-ui-design`.
abstract final class CcColors {
  static const bg = Color(0xFF141518);
  static const panel = Color(0xFF1D1F23);
  static const elevated = Color(0xFF24272C);
  static const elevated2 = Color(0xFF2C3036);
  static const border = Color(0xFF2A2D33);
  static const borderStrong = Color(0xFF34383F);

  static const textPrimary = Color(0xFFE8EAED);
  static const textSecondary = Color(0xFF9AA0A6);
  static const textTertiary = Color(0xFF6B7076);

  static const accent = Color(0xFFFF5A5F);
  static const accentDim = Color(0xFF4A2426);
  /// Text/icon colour used on top of [accent] fills.
  static const onAccent = bg;

  static const videoPlate = Color(0xFF3B4F6B);
  static const videoPlate2 = Color(0xFF4A6382);
  static const audioWave = Color(0xFF3ED598);
  static const audioPlate = Color(0xFF1F3B30);
  static const textClip = Color(0xFF8B6FE8);
  static const textClipPlate = Color(0xFF2E2645);

  static const markerYellow = Color(0xFFF5C518);
  /// "Magnet" alignment guide lines drawn while dragging a clip on the
  /// canvas — kept distinct from [accent] so a snap line reads differently
  /// from the gizmo's own outline.
  static const snapGuide = Color(0xFFFF2ECC);
  static const error = Color(0xFFFF5252);
  static const warning = Color(0xFFFFB020);
  static const success = Color(0xFF3ED598);

  static const scrim = Color(0x66000000);
  static const scrimStrong = Color(0x70000000);
  static const badgeBg = Color(0x99000000);
}

abstract final class CcRadius {
  static const double sm = 4;
  static const double md = 8;
  static const double lg = 12;

  static const brSm = BorderRadius.all(Radius.circular(sm));
  static const brMd = BorderRadius.all(Radius.circular(md));
  static const brLg = BorderRadius.all(Radius.circular(lg));
}

/// Typography. The design uses Inter; we fall back to the platform UI font
/// when Inter is not installed.
abstract final class CcType {
  static const family = 'Inter';
  static const fallback = <String>[
    'SF Pro Text',
    '.SF NS Text',
    'Helvetica Neue',
    'Segoe UI',
  ];

  static const _regular = FontWeight.w400;
  static const medium = FontWeight.w500;
  static const semibold = FontWeight.w600;
  static const bold = FontWeight.w700;

  static TextStyle style({
    required double size,
    FontWeight weight = _regular,
    Color color = CcColors.textPrimary,
    double? height,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontFamily: family,
      fontFamilyFallback: fallback,
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  /// Base style handed to `WidgetsApp.textStyle`.
  static final base = style(size: 13);

  // Named ramp used across the screens.
  static final title = style(size: 20, weight: semibold);
  static final dialogTitle = style(size: 16, weight: semibold);
  static final appName = style(size: 16, weight: bold);
  static final cardTitle = style(size: 15, weight: semibold);
  static final panelTitle = style(size: 14, weight: semibold);
  static final body = style(size: 13);
  static final bodyStrong = style(size: 13, weight: semibold);
  static final label = style(size: 12, weight: medium, color: CcColors.textSecondary);
  static final small = style(size: 12, color: CcColors.textSecondary);
  static final tiny = style(size: 11, color: CcColors.textTertiary);
  static final micro = style(size: 10, color: CcColors.textTertiary);
  static final nano = style(size: 9, color: CcColors.textTertiary);

  /// Uppercase section headers inside the inspector.
  static final sectionHeader = style(
    size: 10,
    weight: semibold,
    color: CcColors.textTertiary,
    letterSpacing: 0.4,
  );
}

/// Common decorations shared by panels, cards and inputs.
abstract final class CcDeco {
  static BoxDecoration panel({BorderRadius? radius, Border? border}) =>
      BoxDecoration(color: CcColors.panel, borderRadius: radius, border: border);

  static BoxDecoration input({bool focused = false}) => BoxDecoration(
        color: CcColors.elevated,
        borderRadius: CcRadius.brMd,
        border: Border.all(
          color: focused ? CcColors.accent : CcColors.borderStrong,
        ),
      );

  static BoxDecoration selectableTile({required bool selected, double radius = CcRadius.md}) =>
      BoxDecoration(
        color: selected ? CcColors.accentDim : CcColors.elevated,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: selected ? CcColors.accent : CcColors.borderStrong,
          width: selected ? 1.5 : 1,
        ),
      );

  static const dialogShadow = <BoxShadow>[
    BoxShadow(color: Color(0x80000000), offset: Offset(0, 20), blurRadius: 60),
  ];

  static const slideOverShadow = <BoxShadow>[
    BoxShadow(color: Color(0x60000000), offset: Offset(-16, 0), blurRadius: 40),
  ];
}

/// Hairline separators. The design draws them as 1px strokes on one side.
abstract final class CcBorders {
  static const bottom = Border(bottom: BorderSide(color: CcColors.border));
  static const top = Border(top: BorderSide(color: CcColors.border));
  static const left = Border(left: BorderSide(color: CcColors.border));
  static const right = Border(right: BorderSide(color: CcColors.border));
  static const all = Border.fromBorderSide(BorderSide(color: CcColors.border));
  static const allStrong = Border.fromBorderSide(BorderSide(color: CcColors.borderStrong));
}
