import 'dart:async';

import 'package:flutter/widgets.dart' hide Clip;

import '../../../../../data/template.dart';
import '../../../../../data/template_library.dart';
import '../../../../../data/transition.dart';
import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/cc_dialog.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../models/rational.dart';
import '../../../../../state/editor_controller.dart';
import '../../../../../state/template_edits.dart';
import '../../../../../state/timeline_edits.dart';

/// Opens a dialog over the editor and completes with whatever it returns.
Future<T?> _showDialog<T>(
  BuildContext context,
  Widget Function(void Function(T? result) finish) builder,
) {
  final completer = Completer<T?>();
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  void finish(T? result) {
    if (completer.isCompleted) return;
    entry.remove();
    completer.complete(result);
  }

  entry = OverlayEntry(
    builder: (context) =>
        CcModalBarrier(onDismiss: () => finish(null), child: builder(finish)),
  );
  overlay.insert(entry);
  return completer.future;
}

/// "Save selection as template…" (TPL-4/5/6). Returns the saved template, or
/// null when the user cancelled or there was nothing selected.
Future<ClipTemplate?> showSaveTemplateDialog(
  BuildContext context,
  EditorController controller,
) {
  final draft = controller.captureTemplate(
    name: _suggestedName(controller),
    clipIds: controller.selection.toList(),
  );
  if (draft == null) return Future.value(null);
  return _showDialog<ClipTemplate>(
    context,
    (finish) => _SaveTemplateDialog(draft: draft, onFinish: finish),
  );
}

String _suggestedName(EditorController c) {
  final text = c.selectedClips.firstWhere(
    (clip) => clip.text != null,
    orElse: () => c.selectedClips.first,
  );
  final content = text.text?.content.trim() ?? '';
  if (content.isEmpty) return text.label.isEmpty ? 'Template' : text.label;
  final line = content.split('\n').first.trim();
  return line.length <= 40 ? line : line.substring(0, 40);
}

/// The insert form: one field per slot, both edges, and the drop mode
/// (TPL-10/11/13). Returns the result so the panel can surface warnings.
Future<TemplateInsertResult?> showInsertTemplateDialog(
  BuildContext context,
  EditorController controller,
  ClipTemplate template,
) {
  return _showDialog<TemplateInsertResult>(
    context,
    (finish) => _InsertTemplateDialog(
      controller: controller,
      template: template,
      onFinish: finish,
    ),
  );
}

// --- Save -------------------------------------------------------------------

class _SaveTemplateDialog extends StatefulWidget {
  const _SaveTemplateDialog({required this.draft, required this.onFinish});

  final ClipTemplate draft;
  final void Function(ClipTemplate?) onFinish;

  @override
  State<_SaveTemplateDialog> createState() => _SaveTemplateDialogState();
}

class _SaveTemplateDialogState extends State<_SaveTemplateDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.draft.name,
  );
  late final TextEditingController _category = TextEditingController();
  late final TextEditingController _description = TextEditingController();

  /// Slot id → the label field for it. Kept alive for the dialog's lifetime so
  /// typing in one does not rebuild the others' text away.
  final Map<String, TextEditingController> _labels = {};

  /// Which proposals survive the save. Text and duration are proposed on,
  /// media off: swapping footage is the rarer intent (TPL-5).
  late final Set<String> _enabled = {
    for (final slot in widget.draft.slots)
      if (slot.kind != SlotKind.media) slot.id,
  };

  late final TemplateEdge _edgeIn = widget.draft.edgeIn;
  late final TemplateEdge _edgeOut = widget.draft.edgeOut;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _description.dispose();
    for (final c in _labels.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _label(TemplateSlot slot) => _labels.putIfAbsent(
    slot.id,
    () => TextEditingController(text: slot.name),
  );

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final template = widget.draft;
    template
      ..name = _name.text.trim().isEmpty ? 'Template' : _name.text.trim()
      ..category = _category.text.trim()
      ..description = _description.text.trim();
    for (final slot in template.slots.toList()) {
      if (!_enabled.contains(slot.id)) {
        template.slots.remove(slot);
        continue;
      }
      final label = _labels[slot.id]?.text.trim() ?? '';
      if (label.isNotEmpty) slot.name = label;
    }
    await TemplateLibrary.instance.save(template);
    widget.onFinish(template);
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    return CcDialogShell(
      title: 'Save as template',
      width: 520,
      onClose: () => widget.onFinish(null),
      sections: [
        CcField(
          label: 'Name',
          child: CcTextField(controller: _name, autofocus: true),
        ),
        Row(
          children: [
            Expanded(
              child: CcField(
                label: 'Category',
                child: CcTextField(
                  controller: _category,
                  placeholder: 'Bumpers, lower thirds…',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: CcField(
                label: 'Contents',
                child: _Readout(
                  '${draft.clips.length} clips · '
                  '${draft.transitions.length} transitions · '
                  '${draft.duration.seconds.toStringAsFixed(1)} s',
                ),
              ),
            ),
          ],
        ),
        CcField(
          label: 'Description',
          child: CcTextField(
            controller: _description,
            placeholder: 'What this chunk is for',
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const CcSectionHeader('EDITABLE ON INSERT'),
            const SizedBox(height: 10),
            for (final slot in draft.slots) ...[
              _SlotRow(
                slot: slot,
                checked: _enabled.contains(slot.id),
                label: _label(slot),
                onToggle: () => setState(() {
                  _enabled.contains(slot.id)
                      ? _enabled.remove(slot.id)
                      : _enabled.add(slot.id);
                }),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const CcSectionHeader('EDGE TRANSITIONS'),
            const SizedBox(height: 4),
            Text(
              'How this chunk joins the clips around it. Handles are checked '
              'on insert, exactly like a hand-made transition.',
              style: CcType.style(
                size: 11,
                color: CcColors.textTertiary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            EdgeEditor(
              label: 'Opening',
              edge: _edgeIn,
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: 8),
            EdgeEditor(
              label: 'Closing',
              edge: _edgeOut,
              onChanged: () => setState(() {}),
            ),
          ],
        ),
      ],
      actions: [
        CcButton(
          label: 'Cancel',
          kind: CcButtonKind.secondary,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          onPressed: () => widget.onFinish(null),
        ),
        CcButton(
          label: _saving ? 'Saving…' : 'Save template',
          padding: const EdgeInsets.symmetric(horizontal: 18),
          onPressed: _save,
        ),
      ],
    );
  }
}

class _SlotRow extends StatelessWidget {
  const _SlotRow({
    required this.slot,
    required this.checked,
    required this.label,
    required this.onToggle,
  });

  final TemplateSlot slot;
  final bool checked;
  final TextEditingController label;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CcCheckbox(checked: checked, onTap: onToggle),
        const SizedBox(width: 10),
        SizedBox(
          width: 76,
          child: Text(switch (slot.kind) {
            SlotKind.text => 'Text',
            SlotKind.media => 'Media',
            SlotKind.duration => 'Duration',
          }, style: CcType.style(size: 11, color: CcColors.textTertiary)),
        ),
        Expanded(
          child: CcTextField(
            controller: label,
            height: 30,
            placeholder: slot.hint,
          ),
        ),
      ],
    );
  }
}

// --- Insert -----------------------------------------------------------------

class _InsertTemplateDialog extends StatefulWidget {
  const _InsertTemplateDialog({
    required this.controller,
    required this.template,
    required this.onFinish,
  });

  final EditorController controller;
  final ClipTemplate template;
  final void Function(TemplateInsertResult?) onFinish;

  @override
  State<_InsertTemplateDialog> createState() => _InsertTemplateDialogState();
}

class _InsertTemplateDialogState extends State<_InsertTemplateDialog> {
  final Map<String, TextEditingController> _fields = {};

  /// Media slots hold a project asset id rather than free text.
  final Map<String, String> _mediaChoice = {};

  late final TemplateEdge _edgeIn = widget.template.edgeIn.copy();
  late final TemplateEdge _edgeOut = widget.template.edgeOut.copy();
  DropMode _mode = DropMode.insert;
  bool _inserting = false;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _field(TemplateSlot slot) => _fields.putIfAbsent(
    slot.id,
    () => TextEditingController(text: slot.defaultValue),
  );

  Future<void> _insert() async {
    if (_inserting) return;
    setState(() => _inserting = true);
    final values = <String, String>{};
    for (final slot in widget.template.slots) {
      switch (slot.kind) {
        case SlotKind.media:
          final asset = _mediaChoice[slot.id];
          if (asset != null) values[slot.id] = asset;
        case SlotKind.text:
        case SlotKind.duration:
          values[slot.id] = _fields[slot.id]?.text ?? slot.defaultValue;
      }
    }
    final result = await widget.controller.insertTemplateResolvingMedia(
      widget.template,
      at: widget.controller.playhead,
      slotValues: values,
      mode: _mode,
      edgeIn: _edgeIn,
      edgeOut: _edgeOut,
    );
    widget.onFinish(result);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.template;
    final slots = t.slots;
    return CcDialogShell(
      title: 'Insert ${t.name}',
      width: 520,
      onClose: () => widget.onFinish(null),
      sections: [
        if (slots.isEmpty)
          Text(
            'This template has no editable parts — it inserts as authored.',
            style: CcType.style(size: 12, color: CcColors.textSecondary),
          ),
        for (final slot in slots)
          CcField(
            label: slot.name,
            child: switch (slot.kind) {
              SlotKind.media => _MediaPicker(
                controller: widget.controller,
                assetId: _mediaChoice[slot.id],
                fallback: slot.defaultValue,
                onChanged: (id) => setState(() => _mediaChoice[slot.id] = id),
              ),
              SlotKind.text || SlotKind.duration => CcTextField(
                controller: _field(slot),
                placeholder: slot.hint,
              ),
            },
          ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const CcSectionHeader('EDGE TRANSITIONS'),
            const SizedBox(height: 10),
            EdgeEditor(
              label: 'Opening',
              edge: _edgeIn,
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: 8),
            EdgeEditor(
              label: 'Closing',
              edge: _edgeOut,
              onChanged: () => setState(() {}),
            ),
          ],
        ),
        CcField(
          label: 'Placement',
          child: CcSegmented(
            height: 30,
            expand: true,
            selectedIndex: _mode == DropMode.insert ? 0 : 1,
            onChanged: (i) => setState(
              () => _mode = i == 0 ? DropMode.insert : DropMode.overwrite,
            ),
            children: [
              Text('Ripple insert', style: CcType.style(size: 11)),
              Text('Overwrite', style: CcType.style(size: 11)),
            ],
          ),
        ),
      ],
      actions: [
        CcButton(
          label: 'Cancel',
          kind: CcButtonKind.secondary,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          onPressed: () => widget.onFinish(null),
        ),
        CcButton(
          label: _inserting ? 'Inserting…' : 'Insert at playhead',
          padding: const EdgeInsets.symmetric(horizontal: 18),
          onPressed: _insert,
        ),
      ],
    );
  }
}

class _MediaPicker extends StatelessWidget {
  const _MediaPicker({
    required this.controller,
    required this.assetId,
    required this.fallback,
    required this.onChanged,
  });

  final EditorController controller;
  final String? assetId;
  final String fallback;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final asset = assetId == null ? null : controller.doc.assetById(assetId!);
    final assets = controller.doc.media
        .where((a) => a.type != 'audio')
        .toList();
    return Builder(
      builder: (context) => CcDropdown(
        value:
            asset?.name ??
            (fallback.isEmpty ? 'Keep authored media' : '$fallback (authored)'),
        bordered: true,
        width: double.infinity,
        onTap: assets.isEmpty
            ? null
            : () => showCcMenuBelow(context, [
                for (final a in assets)
                  CcMenuItem(a.name, onTap: () => onChanged(a.id)),
              ]),
      ),
    );
  }
}

// --- Shared -----------------------------------------------------------------

/// Enable + type + duration for one edge of a template (TPL-8/10).
class EdgeEditor extends StatelessWidget {
  const EdgeEditor({
    super.key,
    required this.label,
    required this.edge,
    required this.onChanged,
  });

  final String label;
  final TemplateEdge edge;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CcCheckbox(
          checked: edge.enabled,
          onTap: () {
            edge.enabled = !edge.enabled;
            onChanged();
          },
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: CcType.style(size: 11, color: CcColors.textTertiary),
          ),
        ),
        Expanded(
          child: Builder(
            builder: (context) => CcDropdown(
              value: transitionTypeLabel(edge.type),
              bordered: true,
              height: 30,
              fontSize: 12,
              width: double.infinity,
              onTap: !edge.enabled
                  ? null
                  : () => showCcMenuBelow(context, [
                      for (final entry in kTransitionCatalog.entries)
                        CcMenuItem(
                          entry.value,
                          onTap: () {
                            edge.type = entry.key;
                            edge.easing = Transition.defaultEasingFor(
                              entry.key,
                            );
                            onChanged();
                          },
                        ),
                    ]),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 84,
          child: Builder(
            builder: (context) => CcDropdown(
              value: '${edge.duration.seconds.toStringAsFixed(2)} s',
              bordered: true,
              height: 30,
              fontSize: 12,
              width: double.infinity,
              onTap: !edge.enabled
                  ? null
                  : () => showCcMenuBelow(context, [
                      for (final seconds in const [
                        0.25,
                        0.5,
                        0.75,
                        1.0,
                        1.5,
                        2.0,
                      ])
                        CcMenuItem(
                          '${seconds.toStringAsFixed(2)} s',
                          onTap: () {
                            edge.duration = Rt.fromSeconds(seconds);
                            onChanged();
                          },
                        ),
                    ]),
            ),
          ),
        ),
      ],
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: CcRadius.brMd,
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: CcType.style(size: 12, color: CcColors.textSecondary),
      ),
    );
  }
}
