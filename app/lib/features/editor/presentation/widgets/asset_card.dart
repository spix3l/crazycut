import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../state/editor_controller.dart';
import '../../../../state/proxy_service.dart';
import '../models/editor_models.dart';

/// Media-pool tile: poster frame (or gradient plate), duration badge, name and
/// metadata, plus proxy/offline state.
class AssetCard extends StatelessWidget {
  const AssetCard({
    super.key,
    required this.item,
    this.usageCount = 0,
    this.proxyState = ProxyState.none,
    this.proxyProgress = 0,
    this.onTap,
    this.onDoubleTap,
    this.onContextMenu,
  });

  final PoolItem item;
  final int usageCount;
  final ProxyState proxyState;
  final double proxyProgress;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;

  /// Anchors the right-click menu to the card itself.
  final void Function(BuildContext anchor)? onContextMenu;

  @override
  Widget build(BuildContext context) {
    final asset = item.asset;
    final preparing = item.status == ImportStatus.probing;
    final failed = item.status == ImportStatus.failed;
    final offline = asset.offline;

    return Builder(
      builder: (cardContext) => GestureDetector(
      onSecondaryTapDown:
          onContextMenu == null ? null : (_) => onContextMenu!(cardContext),
      child: CcTappable(
        onTap: onTap,
        child: Opacity(
          opacity: preparing ? 0.55 : 1,
          child: Container(
            decoration: BoxDecoration(
              color: CcColors.elevated,
              borderRadius: CcRadius.brSm,
              border: offline ? Border.all(color: CcColors.warning) : null,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                AspectRatio(
                  aspectRatio: 130 / 64,
                  child: DecoratedBox(
                    decoration: BoxDecoration(gradient: asset.kind.plate),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (item.thumb != null)
                          Image.memory(item.thumb!, fit: BoxFit.cover, gaplessPlayback: true),
                        Positioned(
                          left: 6,
                          top: 6,
                          child: CcIcon(asset.kind.icon, size: 12, color: const Color(0xCCFFFFFF)),
                        ),
                        if (usageCount > 0)
                          Positioned(
                            right: 6,
                            top: 5,
                            child: CcBadge(
                              '$usageCount×',
                              fontSize: 9,
                              radius: 3,
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            ),
                          ),
                        if (!asset.duration.isZero)
                          Positioned(
                            right: 6,
                            bottom: 5,
                            child: CcBadge(
                              formatDuration(asset.duration.seconds),
                              fontSize: 9,
                              radius: 3,
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            ),
                          ),
                        if (proxyState == ProxyState.running)
                          Positioned(
                            left: 6,
                            bottom: 6,
                            child: _ProxyChip(
                              label: '${(proxyProgress * 100).round()}%',
                              icon: LucideIcons.loaderCircle,
                            ),
                          )
                        else if (proxyState == ProxyState.ready || asset.proxyPath != null)
                          const Positioned(
                            left: 6,
                            bottom: 6,
                            child: _ProxyChip(label: 'proxy', icon: LucideIcons.check),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        asset.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CcType.style(size: 11, weight: CcType.medium),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        failed
                            ? 'Import failed'
                            : preparing
                                ? 'Preparing…'
                                : asset.metaLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CcType.nano,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}

class _ProxyChip extends StatelessWidget {
  const _ProxyChip({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: CcColors.badgeBg,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CcIcon(icon, size: 9, color: CcColors.success),
          const SizedBox(width: 3),
          Text(label, style: CcType.style(size: 9, color: CcColors.textSecondary)),
        ],
      ),
    );
  }
}
