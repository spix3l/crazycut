import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../data/project.dart';
import '../../../../state/editor_controller.dart';
import '../../../../state/timeline_edits.dart';
import '../models/editor_models.dart';
import 'asset_card.dart';
import 'templates/templates_panel.dart';

/// Left rail: search, import drop zone and the asset grid. Cards are draggable
/// onto the timeline (TIM-5) and carry their own context menu (IMP-12).
class MediaPool extends StatefulWidget {
  const MediaPool({
    super.key,
    required this.controller,
    this.onImport,
    this.dropActive = false,
  });

  static const double width = 280;

  final EditorController controller;
  final VoidCallback? onImport;

  /// Highlights the drop zone while files hover the window.
  final bool dropActive;

  @override
  State<MediaPool> createState() => _MediaPoolState();
}

class _MediaPoolState extends State<MediaPool> {
  final _search = TextEditingController();
  bool _listView = false;

  /// 0 = media, 1 = templates. The rail hosts both because they answer the
  /// same question — "what do I put on the timeline next?" (TPL-2).
  int _tab = 0;
  MediaPoolFilter _filter = MediaPoolFilter.all;

  EditorController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<PoolItem> get _items {
    final query = _search.text.trim().toLowerCase();
    final items = c.pool.values.toList()
      ..sort(
        (a, b) =>
            a.asset.name.toLowerCase().compareTo(b.asset.name.toLowerCase()),
      );
    return items.where((item) {
      final matchesType =
          _filter == MediaPoolFilter.all || item.asset.kind == _filter.kind;
      final matchesSearch =
          query.isEmpty || item.asset.name.toLowerCase().contains(query);
      return matchesType && matchesSearch;
    }).toList();
  }

  void _menu(PoolItem item, BuildContext anchorContext) {
    final asset = item.asset;
    showCcMenu(anchorContext, [
      CcMenuItem(
        'Insert at playhead',
        onTap: () =>
            c.placeAsset(asset.id, at: c.playhead, mode: DropMode.overwrite),
      ),
      CcMenuItem('Append to timeline', onTap: () => c.placeAsset(asset.id)),
      // Per-drop override of the toolbar's auto-link toggle (AUD-6).
      if (asset.type == 'video' && asset.hasAudio)
        CcMenuItem(
          c.linkAudioOnAdd ? 'Append picture only' : 'Append with linked audio',
          onTap: () => c.placeAsset(asset.id, withAudio: !c.linkAudioOnAdd),
        ),
      if (asset.type == 'video')
        CcMenuItem(
          'Generate proxy now',
          separatorBefore: true,
          onTap: () => c.proxies.request(asset, force: true),
        ),
      CcMenuItem(
        asset.offline ? 'Relink…' : 'Reveal in folder',
        onTap: () => widget.onImport == null ? null : _reveal(item),
      ),
      CcMenuItem(
        'Remove from project',
        danger: true,
        separatorBefore: true,
        onTap: () => c.removeAsset(asset.id, force: true),
      ),
    ]);
  }

  void _reveal(PoolItem item) => c.revealAsset(item.asset.id);

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final isEmpty = c.pool.isEmpty;
    final offline = c.offlineAssets;

    return Container(
      width: MediaPool.width,
      decoration: const BoxDecoration(
        color: CcColors.panel,
        border: CcBorders.right,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CcTabBar(
            tabs: const ['Media', 'Templates'],
            selectedIndex: _tab,
            onChanged: (index) => setState(() => _tab = index),
          ),
          Expanded(
            child: _tab == 0
                ? _mediaTab(items, isEmpty: isEmpty, offline: offline)
                : TemplatesPanel(controller: c),
          ),
        ],
      ),
    );
  }

  Widget _mediaTab(
    List<PoolItem> items, {
    required bool isEmpty,
    required List<MediaAsset> offline,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Spacer(),
                  CcTappable(
                    onTap: () => setState(() => _listView = false),
                    child: CcIcon(
                      LucideIcons.layoutGrid,
                      size: 14,
                      color: _listView
                          ? CcColors.textTertiary
                          : CcColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  CcTappable(
                    onTap: () => setState(() => _listView = true),
                    child: CcIcon(
                      LucideIcons.list,
                      size: 14,
                      color: _listView
                          ? CcColors.textPrimary
                          : CcColors.textTertiary,
                    ),
                  ),
                ],
              ),
              if (!isEmpty) ...[
                const SizedBox(height: 10),
                CcTextField(
                  placeholder: 'Search media',
                  icon: LucideIcons.search,
                  height: 29,
                  bordered: false,
                  radius: CcRadius.sm,
                  controller: _search,
                ),
                const SizedBox(height: 8),
                CcSegmented(
                  height: 28,
                  padding: 2,
                  expand: true,
                  selectedIndex: _filter.index,
                  onChanged: (index) =>
                      setState(() => _filter = MediaPoolFilter.values[index]),
                  children: [
                    for (final filter in MediaPoolFilter.values)
                      Text(
                        filter.label,
                        style: CcType.style(size: 10, weight: CcType.medium),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                _ImportDropZone(
                  onTap: widget.onImport,
                  active: widget.dropActive,
                ),
              ],
              if (offline.isNotEmpty) ...[
                const SizedBox(height: 10),
                _MissingMediaBanner(count: offline.length),
              ],
            ],
          ),
        ),
        Expanded(
          child: isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: CcEmptyState(
                    icon: LucideIcons.cloudUpload,
                    title: 'No media yet',
                    description: 'Drag files or folders here, or',
                    footnote: 'MP4 · MOV · WAV · PNG · SVG and more',
                    action: CcTappable(
                      onTap: widget.onImport,
                      child: Text(
                        'browse your files',
                        style: CcType.style(
                          size: 11,
                          weight: CcType.semibold,
                          color: CcColors.accent,
                        ),
                      ),
                    ),
                  ),
                )
              : _grid(items),
        ),
        if (c.lastSkipped.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Text(
              'Skipped ${c.lastSkipped.length} unsupported file'
              '${c.lastSkipped.length == 1 ? '' : 's'}',
              style: CcType.nano,
            ),
          ),
      ],
    );
  }

  Widget _grid(List<PoolItem> items) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${items.length} items', style: CcType.tiny),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 8.0;
              final columns = _listView ? 1 : 2;
              final cardWidth =
                  (constraints.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final item in items)
                    SizedBox(
                      width: cardWidth,
                      child: Draggable<String>(
                        data: item.asset.id,
                        dragAnchorStrategy: pointerDragAnchorStrategy,
                        feedback: _DragGhost(name: item.asset.name),
                        child: AssetCard(
                          item: item,
                          usageCount: c.doc.usageCount(item.asset.id),
                          proxyState: c.proxies.stateOf(item.asset.id),
                          proxyProgress: c.proxies.progressOf(item.asset.id),
                          onTap: () => c.placeAsset(item.asset.id),
                          onContextMenu: (anchor) => _menu(item, anchor),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _DragGhost extends StatelessWidget {
  const _DragGhost({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(-60, -14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: CcColors.elevated2,
          borderRadius: CcRadius.brSm,
          border: Border.all(color: CcColors.accent),
        ),
        child: Text(name, style: CcType.style(size: 11, weight: CcType.medium)),
      ),
    );
  }
}

class _MissingMediaBanner extends StatelessWidget {
  const _MissingMediaBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: CcRadius.brSm,
        border: Border.all(color: CcColors.warning),
      ),
      child: Row(
        children: [
          const CcIcon(
            LucideIcons.triangleAlert,
            size: 12,
            color: CcColors.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$count file${count == 1 ? '' : 's'} offline — right-click to relink',
              style: CcType.style(size: 10, color: CcColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImportDropZone extends StatelessWidget {
  const _ImportDropZone({this.onTap, this.active = false});

  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Container(
        key: const ValueKey('media-import-control'),
        height: 38,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: active ? CcColors.elevated2 : CcColors.elevated,
          borderRadius: CcRadius.brMd,
          border: active
              ? Border.all(color: CcColors.accent)
              : CcBorders.allStrong,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CcIcon(
              LucideIcons.cloudUpload,
              size: 14,
              color: active ? CcColors.accent : CcColors.textSecondary,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                active ? 'Drop to import' : 'Drop files or click to import',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: CcType.style(
                  size: 10,
                  weight: CcType.medium,
                  color: active ? CcColors.textPrimary : CcColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum MediaPoolFilter { all, videos, audios, images }

extension MediaPoolFilterPresentation on MediaPoolFilter {
  String get label => switch (this) {
    MediaPoolFilter.all => 'All',
    MediaPoolFilter.videos => 'Videos',
    MediaPoolFilter.audios => 'Audios',
    MediaPoolFilter.images => 'Images',
  };

  MediaKind? get kind => switch (this) {
    MediaPoolFilter.all => null,
    MediaPoolFilter.videos => MediaKind.video,
    MediaPoolFilter.audios => MediaKind.audio,
    MediaPoolFilter.images => MediaKind.image,
  };
}
