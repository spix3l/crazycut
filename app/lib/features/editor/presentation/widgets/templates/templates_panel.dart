import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/cc_dialog.dart';
import '../../../../../core/widgets/empty_state.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/template.dart';
import '../../../../../data/template_library.dart';
import '../../../../../state/editor_controller.dart';
import 'template_dialogs.dart';

/// Templates tab of the left rail (TPL-2): the shared library, one card per
/// template, with insert as the primary action.
class TemplatesPanel extends StatefulWidget {
  const TemplatesPanel({super.key, required this.controller});

  final EditorController controller;

  @override
  State<TemplatesPanel> createState() => _TemplatesPanelState();
}

class _TemplatesPanelState extends State<TemplatesPanel> {
  final _search = TextEditingController();
  final _library = TemplateLibrary.instance;
  List<String> _warnings = const [];
  String? _status;

  EditorController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _library.ensureLoaded();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<ClipTemplate> get _items {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return _library.templates;
    return _library.templates
        .where(
          (t) =>
              t.name.toLowerCase().contains(query) ||
              t.category.toLowerCase().contains(query) ||
              t.description.toLowerCase().contains(query),
        )
        .toList();
  }

  Future<void> _saveSelection() async {
    if (c.selection.isEmpty) {
      setState(() => _status = 'Select clips on the timeline first');
      return;
    }
    final saved = await showSaveTemplateDialog(context, c);
    if (!mounted || saved == null) return;
    setState(() {
      _warnings = const [];
      _status = 'Saved "${saved.name}"';
    });
  }

  Future<void> _insert(ClipTemplate template) async {
    final result = await showInsertTemplateDialog(context, c, template);
    if (!mounted || result == null) return;
    setState(() {
      _warnings = result.warnings;
      _status = result.isEmpty
          ? 'Nothing was inserted — the target lanes are locked'
          : 'Inserted ${result.clipIds.length} clips';
    });
  }

  void _menu(ClipTemplate template, Offset position) {
    showCcMenu(context, position, [
      CcMenuItem('Insert at playhead…', onTap: () => _insert(template)),
      CcMenuItem(
        'Rename…',
        separatorBefore: true,
        onTap: () => _rename(template),
      ),
      CcMenuItem(
        'Duplicate',
        onTap: () async {
          await _library.duplicate(template);
          if (mounted) setState(() {});
        },
      ),
      CcMenuItem(
        'Reveal in folder',
        onTap: () {
          final path = template.filePath;
          if (path != null) c.revealPath(path);
        },
      ),
      CcMenuItem(
        'Delete',
        danger: true,
        separatorBefore: true,
        onTap: () => _delete(template),
      ),
    ]);
  }

  Future<void> _rename(ClipTemplate template) async {
    final name = await promptForText(
      context,
      title: 'Rename template',
      initialValue: template.name,
    );
    if (name == null || name.isEmpty) return;
    await _library.rename(template, name);
    if (mounted) setState(() {});
  }

  Future<void> _delete(ClipTemplate template) async {
    final go = await confirmAction(
      context,
      title: 'Delete template',
      message:
          'Delete "${template.name}"? The clips it was built from are '
          'untouched — only the template file goes.',
    );
    if (!go) return;
    await _library.delete(template);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _library,
      builder: (context, _) {
        final items = _items;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CcTextField(
                    placeholder: 'Search templates',
                    icon: LucideIcons.search,
                    height: 29,
                    bordered: false,
                    radius: CcRadius.sm,
                    controller: _search,
                  ),
                  const SizedBox(height: 8),
                  CcButton(
                    label: 'Save selection as template',
                    icon: LucideIcons.bookmark,
                    kind: CcButtonKind.secondary,
                    height: 32,
                    onPressed: _saveSelection,
                  ),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: CcEmptyState(
                        icon: LucideIcons.layers,
                        title: _library.templates.isEmpty
                            ? 'No templates yet'
                            : 'Nothing matches',
                        description: _library.templates.isEmpty
                            ? 'Select a chunk of timeline — a title card, a '
                                  'bumper — and save it here to reuse it.'
                            : 'Try another search.',
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) => _TemplateCard(
                        template: items[i],
                        onTap: () => _insert(items[i]),
                        onContextMenu: (at) => _menu(items[i], at),
                      ),
                    ),
            ),
            if (_status != null ||
                _warnings.isNotEmpty ||
                _library.unreadableCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_status != null) Text(_status!, style: CcType.tiny),
                    for (final warning in _warnings)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          warning,
                          style: CcType.style(
                            size: 10,
                            color: CcColors.warning,
                            height: 1.3,
                          ),
                        ),
                      ),
                    if (_library.unreadableCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${_library.unreadableCount} template file(s) could '
                          'not be read',
                          style: CcType.style(
                            size: 10,
                            color: CcColors.textTertiary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _TemplateCard extends StatelessWidget {
  const _TemplateCard({
    required this.template,
    required this.onTap,
    required this.onContextMenu,
  });

  final ClipTemplate template;
  final VoidCallback onTap;
  final ValueChanged<Offset> onContextMenu;

  @override
  Widget build(BuildContext context) {
    final slots = template.slots.length;
    final edges = [
      if (template.edgeIn.enabled) 'in',
      if (template.edgeOut.enabled) 'out',
    ];
    return GestureDetector(
      onSecondaryTapDown: (d) => onContextMenu(d.globalPosition),
      child: CcTappable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: CcColors.elevated,
            borderRadius: CcRadius.brMd,
            border: CcBorders.allStrong,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const CcIcon(LucideIcons.layers, size: 13),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      template.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CcType.style(size: 12, weight: CcType.semibold),
                    ),
                  ),
                  CcBadge('${template.duration.seconds.toStringAsFixed(1)}s'),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                [
                  if (template.category.isNotEmpty) template.category,
                  '${template.clips.length} clips',
                  if (slots > 0) '$slots editable',
                  if (edges.isNotEmpty) 'edge ${edges.join('/')}',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.style(size: 10, color: CcColors.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
