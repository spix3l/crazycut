import 'package:flutter/widgets.dart' hide Clip;
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/project.dart';
import '../../../../../data/text_content.dart';
import '../../../../../state/editor_controller.dart';
import '../../../../../state/timeline_edits.dart';

/// A focused text workflow: content, one explicit animation choice, then type.
/// Less common paint effects remain available without dominating every edit.
class TextTab extends StatelessWidget {
  const TextTab({super.key, required this.controller, required this.clip});

  final EditorController controller;
  final Clip clip;

  static const _fonts = <({String family, String label, String kind})>[
    (family: 'default', label: 'System', kind: 'Clean UI'),
    (family: 'Inter', label: 'Inter', kind: 'Neutral sans'),
    (family: 'Roboto', label: 'Roboto', kind: 'Humanist sans'),
    (family: 'Open Sans', label: 'Open Sans', kind: 'Open sans'),
    (family: 'Lato', label: 'Lato', kind: 'Warm sans'),
    (family: 'Montserrat', label: 'Montserrat', kind: 'Geometric sans'),
    (family: 'Poppins', label: 'Poppins', kind: 'Rounded sans'),
    (family: 'Space Grotesk', label: 'Space Grotesk', kind: 'Display sans'),
    (family: 'Oswald', label: 'Oswald', kind: 'Condensed sans'),
    (family: 'Bebas Neue', label: 'Bebas Neue', kind: 'Headline'),
    (
      family: 'Playfair Display',
      label: 'Playfair Display',
      kind: 'Display serif',
    ),
    (family: 'Merriweather', label: 'Merriweather', kind: 'Text serif'),
    (family: 'JetBrains Mono', label: 'JetBrains Mono', kind: 'Monospace'),
  ];

  static const _weights = <({String id, String label})>[
    (id: 'w400', label: 'Regular'),
    (id: 'w500', label: 'Medium'),
    (id: 'w600', label: 'Semi bold'),
    (id: 'w700', label: 'Bold'),
    (id: 'w800', label: 'Extra bold'),
  ];

  EditorController get c => controller;

  @override
  Widget build(BuildContext context) {
    final text = clip.text ?? TextContent();
    final font = _fonts.firstWhere(
      (item) => item.family == text.fontFamily,
      orElse:
          () => (
            family: text.fontFamily,
            label: text.fontFamily,
            kind: 'Custom font',
          ),
    );
    final weight = _weights.firstWhere(
      (item) => item.id == text.fontWeight,
      orElse: () => _weights[2],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionHeader(
            'Content',
            trailing: Text(
              '${text.content.runes.length} characters',
              style: CcType.micro,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: _ContentField(
              key: ValueKey(clip.id),
              initial: text.content,
              autofocus: text.content.isEmpty,
              onCommitted: (value) => c.setTextContent(clip.id, value),
            ),
          ),
          _sectionHeader(
            'Animation',
            trailing:
                text.animation.isEmpty
                    ? Text('None', style: CcType.micro)
                    : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CcIcon(
                          LucideIcons.check,
                          size: 11,
                          color: CcColors.accent,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _presetLabel(text.animation),
                          style: CcType.style(
                            size: 10,
                            weight: CcType.semibold,
                            color: CcColors.accent,
                          ),
                        ),
                      ],
                    ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: _PresetGrid(
              selected: text.animation,
              onSelected:
                  (id) =>
                      id.isEmpty
                          ? c.clearTextPreset(clip.id)
                          : c.applyTextPreset(clip.id, id),
            ),
          ),
          _sectionHeader('Typography'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Builder(
                  builder:
                      (anchorContext) => CcTappable(
                        onTap:
                            () => showCcMenu(anchorContext, [
                              for (final item in _fonts)
                                CcMenuItem(
                                  '${item.label} · ${item.kind}',
                                  checked: item.family == text.fontFamily,
                                  onTap:
                                      () => c.setTextStyle(
                                        clip.id,
                                        (value) =>
                                            value..fontFamily = item.family,
                                      ),
                                ),
                            ]),
                        hoverOpacity: 1,
                        child: Container(
                          height: 56,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: CcDeco.input(),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 44,
                                child: Text(
                                  'Aa',
                                  style: _previewStyle(
                                    text.fontFamily,
                                    text.fontWeight,
                                    size: 22,
                                    color: CcColors.textPrimary,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      font.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: CcType.bodyStrong,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(font.kind, style: CcType.micro),
                                  ],
                                ),
                              ),
                              const CcIcon(
                                LucideIcons.chevronDown,
                                size: 13,
                                color: CcColors.textTertiary,
                              ),
                            ],
                          ),
                        ),
                      ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Builder(
                        builder:
                            (anchorContext) => CcDropdown(
                              value: weight.label,
                              bordered: true,
                              onTap:
                                  () => showCcMenu(anchorContext, [
                                    for (final item in _weights)
                                      CcMenuItem(
                                        item.label,
                                        checked: item.id == text.fontWeight,
                                        onTap:
                                            () => c.setTextStyle(
                                              clip.id,
                                              (value) =>
                                                  value..fontWeight = item.id,
                                            ),
                                      ),
                                  ]),
                            ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: CcSegmented(
                        expand: true,
                        height: 32,
                        selectedIndex: switch (text.align) {
                          'left' => 0,
                          'right' => 2,
                          _ => 1,
                        },
                        children: const [
                          CcIcon(LucideIcons.alignLeft, size: 14),
                          CcIcon(LucideIcons.alignCenter, size: 14),
                          CcIcon(LucideIcons.alignRight, size: 14),
                        ],
                        onChanged:
                            (index) => c.setTextStyle(clip.id, (value) {
                              value.align = switch (index) {
                                0 => 'left',
                                2 => 'right',
                                _ => 'center',
                              };
                              return value;
                            }),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _sectionHeader('Appearance'),
          _colorRow(
            context,
            'Fill',
            text.color,
            (hex) => c.setTextStyle(clip.id, (value) => value..color = hex),
          ),
          _sliderRow(
            'Size',
            text.fontSize,
            12,
            240,
            'px',
            (value) =>
                c.setTextStyle(clip.id, (item) => item..fontSize = value),
          ),
          _sliderRow(
            'Letter spacing',
            text.letterSpacing,
            -10,
            40,
            '',
            (value) =>
                c.setTextStyle(clip.id, (item) => item..letterSpacing = value),
          ),
          _sliderRow(
            'Line height',
            text.lineHeight,
            0.8,
            3.0,
            '×',
            (value) =>
                c.setTextStyle(clip.id, (item) => item..lineHeight = value),
          ),
          _DisclosureSection(
            title: 'Outline',
            summary:
                text.strokeWidth > 0
                    ? '${_number(text.strokeWidth)} px'
                    : 'Off',
            enabled: text.strokeWidth > 0,
            children: [
              _sliderRow(
                'Width',
                text.strokeWidth,
                0,
                20,
                'px',
                (value) => c.setTextStyle(
                  clip.id,
                  (item) => item..strokeWidth = value,
                ),
              ),
              _colorRow(
                context,
                'Color',
                text.strokeColor,
                (hex) =>
                    c.setTextStyle(clip.id, (item) => item..strokeColor = hex),
              ),
            ],
          ),
          _DisclosureSection(
            title: 'Shadow',
            summary:
                text.shadowOpacity > 0
                    ? '${(text.shadowOpacity * 100).round()}%'
                    : 'Off',
            enabled: text.shadowOpacity > 0,
            children: [
              _sliderRow(
                'Opacity',
                text.shadowOpacity,
                0,
                1,
                '',
                (value) => c.setTextStyle(
                  clip.id,
                  (item) => item..shadowOpacity = value,
                ),
              ),
              _sliderRow(
                'Blur',
                text.shadowBlur,
                0,
                60,
                'px',
                (value) =>
                    c.setTextStyle(clip.id, (item) => item..shadowBlur = value),
              ),
              _sliderRow(
                'Horizontal',
                text.shadowOffsetX,
                -60,
                60,
                'px',
                (value) => c.setTextStyle(
                  clip.id,
                  (item) => item..shadowOffsetX = value,
                ),
              ),
              _sliderRow(
                'Vertical',
                text.shadowOffsetY,
                -60,
                60,
                'px',
                (value) => c.setTextStyle(
                  clip.id,
                  (item) => item..shadowOffsetY = value,
                ),
              ),
            ],
          ),
          _DisclosureSection(
            title: 'Background',
            summary: _hasVisibleColor(text.backgroundColor) ? 'On' : 'Off',
            enabled: _hasVisibleColor(text.backgroundColor),
            children: [
              _colorRow(
                context,
                'Fill',
                text.backgroundColor,
                (hex) => c.setTextStyle(
                  clip.id,
                  (item) => item..backgroundColor = hex,
                ),
              ),
              _sliderRow(
                'Padding',
                text.backgroundPadding,
                0,
                80,
                'px',
                (value) => c.setTextStyle(
                  clip.id,
                  (item) => item..backgroundPadding = value,
                ),
              ),
              _sliderRow(
                'Corner radius',
                text.backgroundRadius,
                0,
                80,
                'px',
                (value) => c.setTextStyle(
                  clip.id,
                  (item) => item..backgroundRadius = value,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 16, 14, 7),
    child: CcSectionHeader(title, trailing: trailing),
  );

  Widget _sliderRow(
    String label,
    double value,
    double min,
    double max,
    String unit,
    ValueChanged<double> onChanged,
  ) {
    return SizedBox(
      height: 36,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            SizedBox(width: 92, child: Text(label, style: CcType.label)),
            Expanded(
              child: CcSlider(
                value: ((value - min) / (max - min)).clamp(0.0, 1.0),
                handleSize: 12,
                onChangeStart: () => c.beginGesture('Adjust text $label'),
                onChangeEnd: c.endGesture,
                onChanged:
                    (position) => onChanged(min + position * (max - min)),
              ),
            ),
            SizedBox(
              width: 52,
              child: Text(
                '${_number(value)}$unit',
                textAlign: TextAlign.right,
                style: CcType.style(size: 10, weight: CcType.semibold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _colorRow(
    BuildContext context,
    String label,
    String hex,
    ValueChanged<String> onChanged,
  ) {
    final color = _parseColor(hex);
    return SizedBox(
      height: 36,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            SizedBox(width: 92, child: Text(label, style: CcType.label)),
            Expanded(
              child: Builder(
                builder:
                    (anchorContext) => CcTappable(
                      onTap:
                          () => _openSwatches(anchorContext, color, onChanged),
                      hoverOpacity: 1,
                      child: Container(
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: CcDeco.input(),
                        child: Row(
                          children: [
                            Container(
                              width: 16,
                              height: 16,
                              decoration: BoxDecoration(
                                color: color,
                                borderRadius: BorderRadius.circular(4),
                                border: CcBorders.allStrong,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                hex.toUpperCase(),
                                style: CcType.style(
                                  size: 10,
                                  weight: CcType.medium,
                                ),
                              ),
                            ),
                            const CcIcon(
                              LucideIcons.chevronDown,
                              size: 11,
                              color: CcColors.textTertiary,
                            ),
                          ],
                        ),
                      ),
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openSwatches(
    BuildContext anchorContext,
    Color current,
    ValueChanged<String> onChanged,
  ) {
    const swatches = <Color>[
      Color(0x00FFFFFF),
      Color(0xFFFFFFFF),
      Color(0xFF000000),
      Color(0xFFF5C451),
      Color(0xFFEF6F6C),
      Color(0xFF6FCF97),
      Color(0xFF56CCF2),
      Color(0xFFBB6BD9),
      Color(0xFFFF8A65),
      Color(0xFF4A4A55),
    ];
    showCcMenu(anchorContext, [
      for (final swatch in swatches)
        CcMenuItem(
          swatch.a == 0 ? 'Transparent' : _hex(swatch),
          checked: swatch.toARGB32() == current.toARGB32(),
          onTap: () => onChanged(swatch.a == 0 ? '#00000000' : _hex(swatch)),
        ),
    ]);
  }

  static String _hex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  static Color _parseColor(String hex) {
    var value = hex.replaceFirst('#', '');
    if (value.length == 6) value = 'FF$value';
    return Color(int.tryParse(value, radix: 16) ?? 0xFFFFFFFF);
  }

  static bool _hasVisibleColor(String hex) => _parseColor(hex).a > 0;

  static String _number(double value) =>
      value == value.roundToDouble()
          ? value.round().toString()
          : value.toStringAsFixed(1);

  static String _presetLabel(String id) {
    for (final entry in TimelineEdits.kTextPresets.entries) {
      if (entry.value == id) return entry.key;
    }
    return id;
  }

  static TextStyle _previewStyle(
    String family,
    String weight, {
    required double size,
    required Color color,
  }) {
    final fontWeight = switch (weight) {
      'w400' => FontWeight.w400,
      'w500' => FontWeight.w500,
      'w700' => FontWeight.w700,
      'w800' => FontWeight.w800,
      _ => FontWeight.w600,
    };
    if (family == 'default') {
      return CcType.style(size: size, weight: fontWeight, color: color);
    }
    try {
      return GoogleFonts.getFont(
        family,
        fontSize: size,
        fontWeight: fontWeight,
        color: color,
        height: 1,
      );
    } on Exception {
      return TextStyle(
        fontFamily: family,
        fontSize: size,
        fontWeight: fontWeight,
        color: color,
        height: 1,
      );
    }
  }
}

class _PresetGrid extends StatelessWidget {
  const _PresetGrid({required this.selected, required this.onSelected});

  final String selected;
  final ValueChanged<String> onSelected;

  static const _icons = <String, IconData>{
    '': LucideIcons.minus,
    'fade': LucideIcons.circle,
    'pop': LucideIcons.zoomIn,
    'slideLeft': LucideIcons.arrowLeft,
    'slideRight': LucideIcons.arrowRight,
    'slideUp': LucideIcons.arrowUp,
    'slideDown': LucideIcons.arrowDown,
    'rise': LucideIcons.moveUp,
    'blink': LucideIcons.eye,
    'typewriter': LucideIcons.textCursorInput,
  };

  @override
  Widget build(BuildContext context) {
    final entries = <MapEntry<String, String>>[
      const MapEntry('None', ''),
      ...TimelineEdits.kTextPresets.entries,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - 12) / 3;
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final entry in entries)
              _PresetTile(
                width: width,
                label: entry.key,
                icon: _icons[entry.value] ?? LucideIcons.circle,
                selected: selected == entry.value,
                onTap: () => onSelected(entry.value),
              ),
          ],
        );
      },
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.width,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final double width;
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      hoverOpacity: 1,
      builder:
          (context, hovered, child) => AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: width,
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color:
                  selected
                      ? CcColors.accentDim
                      : hovered
                      ? CcColors.elevated2
                      : CcColors.elevated,
              borderRadius: CcRadius.brSm,
              border: Border.all(
                color: selected ? CcColors.accent : CcColors.borderStrong,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: CcIcon(
                    icon,
                    size: 12,
                    color: selected ? CcColors.accent : CcColors.textSecondary,
                  ),
                ),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CcType.style(
                      size: 10,
                      weight: selected ? CcType.semibold : CcType.medium,
                      color:
                          selected
                              ? CcColors.textPrimary
                              : CcColors.textSecondary,
                    ),
                  ),
                ),
                if (selected)
                  const CcIcon(
                    LucideIcons.check,
                    size: 10,
                    color: CcColors.accent,
                  ),
              ],
            ),
          ),
      child: const SizedBox.shrink(),
    );
  }
}

class _DisclosureSection extends StatefulWidget {
  const _DisclosureSection({
    required this.title,
    required this.summary,
    required this.enabled,
    required this.children,
  });

  final String title;
  final String summary;
  final bool enabled;
  final List<Widget> children;

  @override
  State<_DisclosureSection> createState() => _DisclosureSectionState();
}

class _DisclosureSectionState extends State<_DisclosureSection> {
  late bool _open = widget.enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: const BoxDecoration(border: CcBorders.top),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CcTappable(
            onTap: () => setState(() => _open = !_open),
            hoverOpacity: 1,
            builder:
                (context, hovered, child) => Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  color:
                      hovered
                          ? CcColors.elevated.withValues(alpha: 0.55)
                          : null,
                  child: Row(
                    children: [
                      Text(widget.title, style: CcType.bodyStrong),
                      const Spacer(),
                      Text(
                        widget.summary,
                        style: CcType.style(
                          size: 10,
                          weight:
                              widget.enabled ? CcType.semibold : CcType.medium,
                          color:
                              widget.enabled
                                  ? CcColors.textSecondary
                                  : CcColors.textTertiary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      CcIcon(
                        _open
                            ? LucideIcons.chevronDown
                            : LucideIcons.chevronRight,
                        size: 13,
                        color: CcColors.textTertiary,
                      ),
                    ],
                  ),
                ),
            child: const SizedBox.shrink(),
          ),
          if (_open) ...widget.children,
        ],
      ),
    );
  }
}

class _ContentField extends StatefulWidget {
  const _ContentField({
    super.key,
    required this.initial,
    required this.autofocus,
    required this.onCommitted,
  });

  final String initial;
  final bool autofocus;
  final ValueChanged<String> onCommitted;

  @override
  State<_ContentField> createState() => _ContentFieldState();
}

class _ContentFieldState extends State<_ContentField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void didUpdateWidget(_ContentField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initial != oldWidget.initial &&
        widget.initial != _controller.text) {
      _controller.value = _controller.value.copyWith(
        text: widget.initial,
        selection: TextSelection.collapsed(offset: widget.initial.length),
        composing: TextRange.empty,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CcMultilineTextField(
      controller: _controller,
      autofocus: widget.autofocus,
      placeholder: 'Enter text',
      maxLines: 5,
      minLines: 3,
      onChanged: widget.onCommitted,
    );
  }
}
