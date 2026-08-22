import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/project.dart';
import '../../../../../state/editor_controller.dart';
import '../../../../../data/text_content.dart';
import '../../../../../state/timeline_edits.dart';

/// Text clip editing (TXT-2/3/4): content, style, and the preset gallery that
/// bakes keyframes (TXT-5).
class TextTab extends StatelessWidget {
  const TextTab({super.key, required this.controller, required this.clip});

  final EditorController controller;
  final Clip clip;

  EditorController get c => controller;

  static const _fonts = <String>[
    'default',
    'Inter',
    'Roboto',
    'Open Sans',
    'Lato',
    'Montserrat',
    'Poppins',
    'Playfair Display',
    'Merriweather',
    'Oswald',
    'Bebas Neue',
    'JetBrains Mono',
    'Space Grotesk',
  ];

  static const _weights = ['w400', 'w500', 'w600', 'w700', 'w800'];

  @override
  Widget build(BuildContext context) {
    final text = clip.text ?? TextContent();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Content (TXT-2).
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: _ContentField(
              key: ValueKey(clip.id),
              initial: text.content,
              autofocus: text.content.isEmpty,
              onCommitted: (v) => c.setTextContent(clip.id, v),
            ),
          ),
          _section('Presets'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final preset in TimelineEdits.kTextPresets.keys)
                  CcTappable(
                    onTap: () => c.applyTextPreset(clip.id, preset),
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      decoration: CcDeco.selectableTile(
                        selected: text.animation ==
                            TimelineEdits.kTextPresets[preset],
                        radius: 5,
                      ),
                      child: Text(preset,
                          style: CcType.style(size: 11)),
                    ),
                  ),
              ],
            ),
          ),
          _section('Font'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Expanded(
                  child: Builder(
                    builder: (anchorContext) => CcTappable(
                      onTap: () => showCcMenuBelow(anchorContext, [
                        for (final f in _fonts)
                          CcMenuItem(f,
                              checked: f == text.fontFamily,
                              onTap: () => c.setTextStyle(clip.id,
                                  (t) => t..fontFamily = f)),
                      ]),
                      child: CcDropdown(value: text.fontFamily, bordered: true),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Builder(
                  builder: (anchorContext) => CcTappable(
                    onTap: () => showCcMenuBelow(anchorContext, [
                      for (final w in _weights)
                        CcMenuItem(w.substring(1),
                            checked: w == text.fontWeight,
                            onTap: () => c.setTextStyle(
                                clip.id, (t) => t..fontWeight = w)),
                    ]),
                    child: CcDropdown(
                      value: text.fontWeight.substring(1),
                      width: 56,
                      bordered: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CcSegmented(
                  selectedIndex: switch (text.align) {
                    'left' => 0,
                    'right' => 2,
                    _ => 1,
                  },
                  children: const [
                    CcIcon(LucideIcons.alignLeft, size: 13),
                    CcIcon(LucideIcons.alignCenter, size: 13),
                    CcIcon(LucideIcons.alignRight, size: 13),
                  ],
                  onChanged: (i) => c.setTextStyle(clip.id, (t) {
                    t.align = switch (i) { 0 => 'left', 2 => 'right', _ => 'center' };
                    return t;
                  }),
                ),
              ],
            ),
          ),
          _colorRow(context, 'Color', text.color,
              (hex) => c.setTextStyle(clip.id, (t) => t..color = hex)),
          _sliderRow('Size', text.fontSize, 12, 240, 'px',
              (v) => c.setTextStyle(clip.id, (t) => t..fontSize = v)),
          _sliderRow('Spacing', text.letterSpacing, -10, 40, '',
              (v) => c.setTextStyle(clip.id, (t) => t..letterSpacing = v)),
          _sliderRow('Line height', text.lineHeight, 0.8, 3.0, '×',
              (v) => c.setTextStyle(clip.id, (t) => t..lineHeight = v)),
          _section('Stroke'),
          _sliderRow('Width', text.strokeWidth, 0, 20, 'px',
              (v) => c.setTextStyle(clip.id, (t) => t..strokeWidth = v)),
          _colorRow(context, 'Stroke color', text.strokeColor,
              (hex) => c.setTextStyle(clip.id, (t) => t..strokeColor = hex)),
          _section('Shadow'),
          _sliderRow('Opacity', text.shadowOpacity, 0, 1, '',
              (v) => c.setTextStyle(clip.id, (t) => t..shadowOpacity = v)),
          _sliderRow('Blur', text.shadowBlur, 0, 60, 'px',
              (v) => c.setTextStyle(clip.id, (t) => t..shadowBlur = v)),
          _sliderRow('Offset X', text.shadowOffsetX, -60, 60, 'px',
              (v) => c.setTextStyle(clip.id, (t) => t..shadowOffsetX = v)),
          _sliderRow('Offset Y', text.shadowOffsetY, -60, 60, 'px',
              (v) => c.setTextStyle(clip.id, (t) => t..shadowOffsetY = v)),
          _section('Background box'),
          _colorRow(context, 'Fill', text.backgroundColor,
              (hex) => c.setTextStyle(clip.id, (t) => t..backgroundColor = hex)),
          _sliderRow('Padding', text.backgroundPadding, 0, 80, 'px',
              (v) => c.setTextStyle(clip.id, (t) => t..backgroundPadding = v)),
          _sliderRow('Radius', text.backgroundRadius, 0, 80, 'px',
              (v) => c.setTextStyle(clip.id, (t) => t..backgroundRadius = v)),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
        child: CcSectionHeader(title),
      );

  Widget _sliderRow(String label, double value, double min, double max,
      String unit, ValueChanged<double> onChanged) {
    return SizedBox(
      height: 28,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Expanded(
              flex: 5,
              child: Text(label,
                  style: CcType.style(size: 11, color: CcColors.textSecondary)),
            ),
            Expanded(
              flex: 7,
              child: CcSlider(
                value: ((value - min) / (max - min)).clamp(0.0, 1.0),
                onChanged: (t) => onChanged(min + t * (max - min)),
              ),
            ),
            SizedBox(
              width: 46,
              child: Text(
                '${value.toStringAsFixed(value % 1 == 0 ? 0 : 1)}$unit',
                textAlign: TextAlign.right,
                style: CcType.style(size: 10, weight: CcType.medium),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _colorRow(BuildContext context, String label, String hex,
      ValueChanged<String> onChanged) {
    final color = Color(
        int.tryParse(hex.replaceFirst('#', 'FF'), radix: 16) ?? 0xFFFFFFFF);
    return SizedBox(
      height: 28,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Expanded(
              flex: 5,
              child: Text(label,
                  style: CcType.style(size: 11, color: CcColors.textSecondary)),
            ),
            const Spacer(),
            GestureDetector(
              onTap: () => _openSwatches(context, color, onChanged),
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: CcColors.borderStrong),
                ),
              ),
            ),
            SizedBox(
              width: 22,
              child: Center(child: SizedBox.shrink()),
            ),
          ],
        ),
      ),
    );
  }

  void _openSwatches(BuildContext context, Color current,
      ValueChanged<String> onChanged) {
    const swatches = <Color>[
      Color(0xFFFFFFFF), Color(0xFF000000), Color(0xFFF5C451),
      Color(0xFFEF6F6C), Color(0xFF6FCF97), Color(0xFF56CCF2),
      Color(0xFFBB6BD9), Color(0xFFFF8A65), Color(0xFF4A4A55),
    ];
    showCcMenu(
      context,
      Offset(200, 200),
      [
        for (final s in swatches)
          CcMenuItem(
            '#${s.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
            checked: s.toARGB32() == current.toARGB32(),
            onTap: () => onChanged(
                '#${s.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}'),
          ),
      ],
    );
  }

  /// Multi-line content field that commits per keystroke but keeps its own
  /// controller so the cursor does not jump (TXT-2).
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
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void didUpdateWidget(_ContentField old) {
    super.didUpdateWidget(old);
    // External changes (undo, preset) flow in; typing keeps local state.
    if (widget.initial != old.initial && widget.initial != _controller.text) {
      _controller.text = widget.initial;
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
      placeholder: 'Type…',
      maxLines: 3,
      minLines: 1,
      onChanged: widget.onCommitted,
    );
  }
}
