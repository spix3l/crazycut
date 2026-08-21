import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../../../core/widgets/primitives.dart';
import '../models/editor_models.dart';
import 'asset_card.dart';

/// Left rail: search, import drop zone and the asset grid. Falls back to an
/// empty state when the project has no media yet.
class MediaPool extends StatelessWidget {
  const MediaPool({super.key, required this.assets, this.onImport});

  static const double width = 280;

  final List<MediaAsset> assets;
  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    final isEmpty = assets.isEmpty;
    return Container(
      width: width,
      decoration: const BoxDecoration(color: CcColors.panel, border: CcBorders.right),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text('Media', style: CcType.panelTitle),
                    const Spacer(),
                    CcIcon(
                      LucideIcons.layoutGrid,
                      size: 14,
                      color: isEmpty ? CcColors.textTertiary : CcColors.textPrimary,
                    ),
                    const SizedBox(width: 10),
                    const CcIcon(LucideIcons.list, size: 14, color: CcColors.textTertiary),
                  ],
                ),
                if (!isEmpty) ...[
                  const SizedBox(height: 10),
                  const CcTextField(
                    placeholder: 'Search media',
                    icon: LucideIcons.search,
                    height: 29,
                    bordered: false,
                    radius: CcRadius.sm,
                  ),
                  const SizedBox(height: 10),
                  _ImportDropZone(onTap: onImport),
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
                      footnote: 'MP4 · MOV · WAV · PNG and more',
                      action: CcTappable(
                        onTap: onImport,
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
                : _AssetGrid(assets: assets),
          ),
        ],
      ),
    );
  }
}

class _ImportDropZone extends StatelessWidget {
  const _ImportDropZone({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Container(
        height: 86,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: CcColors.elevated,
          borderRadius: CcRadius.brMd,
          border: CcBorders.allStrong,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CcIcon(LucideIcons.cloudUpload, size: 18),
            const SizedBox(height: 4),
            Text(
              'Drag files or folders',
              style: CcType.style(size: 12, weight: CcType.medium, color: CcColors.textSecondary),
            ),
            const SizedBox(height: 4),
            Text('or click to import', style: CcType.tiny),
          ],
        ),
      ),
    );
  }
}

class _AssetGrid extends StatelessWidget {
  const _AssetGrid({required this.assets});

  final List<MediaAsset> assets;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${assets.length} items', style: CcType.tiny),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 8.0;
              final cardWidth = (constraints.maxWidth - gap) / 2;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final asset in assets)
                    SizedBox(width: cardWidth, child: AssetCard(asset: asset)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
