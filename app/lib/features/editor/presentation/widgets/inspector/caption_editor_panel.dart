import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/caption.dart';
import '../../../../../state/editor_controller.dart';
import 'inspector_rows.dart';

/// Synchronized cue list and correction controls for one typed caption track.
class CaptionEditorPanel extends StatelessWidget {
  const CaptionEditorPanel({super.key, required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final track = controller.selectedCaptionTrack;
    if (track == null) return const SizedBox.shrink();
    final selected = controller.selectedCaptionItem;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          child: Row(
            children: [
              const Expanded(child: CcSectionHeader('CAPTION CUES')),
              CcIconButton(
                icon: LucideIcons.plus,
                size: 26,
                iconSize: 13,
                outlined: true,
                onPressed: () => controller.addCaptionItem(),
              ),
            ],
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 190),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: track.items.length,
            itemBuilder: (context, index) {
              final item = track.items[index];
              final active = item.id == selected?.id;
              return CcTappable(
                key: ValueKey('caption-list-${item.id}'),
                onTap:
                    () =>
                        controller.selectCaption(track.id, item.id, seek: true),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  color: active ? CcColors.textClipPlate : null,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 54,
                        child: Text(
                          _shortTime(item.start.seconds),
                          style: CcType.micro,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          item.text.isEmpty ? '(empty)' : item.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: CcType.style(
                            size: 11,
                            color:
                                active
                                    ? CcColors.textPrimary
                                    : CcColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const CcDivider(),
        if (selected == null)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              'Select a cue in the list or caption lane to correct it.',
              style: CcType.tiny,
            ),
          )
        else
          _CueEditor(controller: controller, track: track, item: selected),
        const CcDivider(),
        _TrackStyleEditor(controller: controller, track: track),
      ],
    );
  }

  static String _shortTime(double seconds) {
    final minutes = seconds ~/ 60;
    final rest = seconds - minutes * 60;
    return '$minutes:${rest.toStringAsFixed(1).padLeft(4, '0')}';
  }
}

class _CueEditor extends StatelessWidget {
  const _CueEditor({
    required this.controller,
    required this.track,
    required this.item,
  });

  final EditorController controller;
  final CaptionTrack track;
  final CaptionItem item;

  @override
  Widget build(BuildContext context) {
    final charactersPerSecond =
        item.duration.seconds <= 0
            ? 0.0
            : item.text.replaceAll(RegExp(r'\s+'), ' ').trim().length /
                item.duration.seconds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: CcSectionHeader('SELECTED CUE'),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: _CommitMultiline(
              key: ValueKey('caption-text-${item.id}'),
              value: item.text,
              onCommit:
                  (text) =>
                      controller.updateCaptionText(track.id, item.id, text),
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: _CommitSingleLine(
              key: ValueKey('caption-speaker-${item.id}'),
              value: item.speaker ?? '',
              placeholder: 'Speaker (optional)',
              onCommit:
                  (speaker) => controller.updateCaptionSpeaker(
                    track.id,
                    item.id,
                    speaker,
                  ),
            ),
          ),
          const SizedBox(height: 4),
          TimecodeRow(
            label: 'Start',
            value: item.start,
            fps: controller.fps,
            onSubmitted:
                (value) =>
                    controller.retimeCaption(track.id, item.id, start: value),
          ),
          TimecodeRow(
            label: 'Duration',
            value: item.duration,
            fps: controller.fps,
            onSubmitted:
                (value) => controller.retimeCaption(
                  track.id,
                  item.id,
                  duration: value,
                ),
          ),
          if (charactersPerSecond > 20)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 2),
              child: Row(
                children: [
                  const CcIcon(
                    LucideIcons.triangleAlert,
                    size: 12,
                    color: CcColors.warning,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${charactersPerSecond.toStringAsFixed(0)} characters/sec may be hard to read.',
                      style: CcType.style(size: 10, color: CcColors.warning),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                CcButton(
                  label: '−1 frame',
                  kind: CcButtonKind.secondary,
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  onPressed:
                      () => controller.nudgeCaption(track.id, item.id, -1),
                ),
                CcButton(
                  label: '+1 frame',
                  kind: CcButtonKind.secondary,
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  onPressed:
                      () => controller.nudgeCaption(track.id, item.id, 1),
                ),
                CcButton(
                  label: 'Split at playhead',
                  kind: CcButtonKind.secondary,
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  onPressed:
                      () => controller.splitCaption(
                        track.id,
                        item.id,
                        controller.playhead,
                      ),
                ),
                CcButton(
                  label: 'Merge next',
                  kind: CcButtonKind.secondary,
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  onPressed:
                      () => controller.mergeCaptionWithNext(track.id, item.id),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackStyleEditor extends StatelessWidget {
  const _TrackStyleEditor({required this.controller, required this.track});

  final EditorController controller;
  final CaptionTrack track;

  @override
  Widget build(BuildContext context) {
    final style = track.style;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: CcSectionHeader('TRACK STYLE · ALL CUES'),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Builder(
              builder:
                  (anchor) => CcDropdown(
                    value: style.preset == 'default' ? 'Default' : style.preset,
                    width: double.infinity,
                    bordered: true,
                    onTap:
                        () => showCcMenu(anchor, [
                          for (final preset in const [
                            'default',
                            'creator',
                            'minimal',
                          ])
                            CcMenuItem(
                              preset == 'default' ? 'Default' : preset,
                              checked: style.preset == preset,
                              onTap:
                                  () => controller.updateCaptionStyle(
                                    track.id,
                                    preset: preset,
                                  ),
                            ),
                        ]),
                  ),
            ),
          ),
          const SizedBox(height: 6),
          SliderRow(
            label: 'Font size',
            value: ((style.fontSize - 12) / 148).clamp(0, 1),
            display: style.fontSize.round().toString(),
            onChanged:
                (value) => controller.updateCaptionStyle(
                  track.id,
                  fontSize: 12 + value * 148,
                ),
            onChangeStart: () => controller.beginGesture('Style captions'),
            onChangeEnd: controller.endGesture,
          ),
          SliderRow(
            label: 'Safe Y',
            value: style.positionY,
            display: '${(style.positionY * 100).round()}%',
            onChanged:
                (value) =>
                    controller.updateCaptionStyle(track.id, positionY: value),
            onChangeStart: () => controller.beginGesture('Style captions'),
            onChangeEnd: controller.endGesture,
          ),
          SliderRow(
            label: 'Max width',
            value: style.maxWidth,
            display: '${(style.maxWidth * 100).round()}%',
            onChanged:
                (value) =>
                    controller.updateCaptionStyle(track.id, maxWidth: value),
            onChangeStart: () => controller.beginGesture('Style captions'),
            onChangeEnd: controller.endGesture,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              children: [
                CcCheckbox(
                  checked: style.highlightWords,
                  onTap:
                      () => controller.updateCaptionStyle(
                        track.id,
                        highlightWords: !style.highlightWords,
                      ),
                ),
                const SizedBox(width: 8),
                Text('Highlight spoken words', style: CcType.small),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CommitMultiline extends StatefulWidget {
  const _CommitMultiline({
    super.key,
    required this.value,
    required this.onCommit,
  });

  final String value;
  final ValueChanged<String> onCommit;

  @override
  State<_CommitMultiline> createState() => _CommitMultilineState();
}

class _CommitMultilineState extends State<_CommitMultiline> {
  late final TextEditingController _text = TextEditingController(
    text: widget.value,
  );
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _text.text != widget.value) {
        widget.onCommit(_text.text);
      }
    });
  }

  @override
  void didUpdateWidget(_CommitMultiline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && widget.value != _text.text) {
      _text.text = widget.value;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CcMultilineTextField(
    controller: _text,
    focusNode: _focus,
    minLines: 2,
    maxLines: 4,
  );
}

class _CommitSingleLine extends StatefulWidget {
  const _CommitSingleLine({
    super.key,
    required this.value,
    required this.placeholder,
    required this.onCommit,
  });

  final String value;
  final String placeholder;
  final ValueChanged<String> onCommit;

  @override
  State<_CommitSingleLine> createState() => _CommitSingleLineState();
}

class _CommitSingleLineState extends State<_CommitSingleLine> {
  late final TextEditingController _text = TextEditingController(
    text: widget.value,
  );
  final FocusNode _focus = FocusNode();

  void _commit([String? _]) {
    if (_text.text != widget.value) {
      widget.onCommit(_text.text);
    }
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_CommitSingleLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && widget.value != _text.text) {
      _text.text = widget.value;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CcTextField(
    controller: _text,
    focusNode: _focus,
    placeholder: widget.placeholder,
    height: 30,
    onSubmitted: _commit,
  );
}
