import 'package:flutter/widgets.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';
import '../models/editor_models.dart';

/// Media-pool tile: gradient plate with a type icon and duration badge,
/// then the file name and its metadata line.
class AssetCard extends StatelessWidget {
  const AssetCard({super.key, required this.asset, this.onTap});

  final MediaAsset asset;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Opacity(
        opacity: asset.preparing ? 0.55 : 1,
        child: Container(
          decoration: const BoxDecoration(
            color: CcColors.elevated,
            borderRadius: CcRadius.brSm,
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
                      if (asset.thumb != null)
                        Image.memory(asset.thumb!, fit: BoxFit.cover, gaplessPlayback: true),
                      Positioned(
                        left: 6,
                        top: 6,
                        child: CcIcon(
                          asset.kind.icon,
                          size: 12,
                          color: const Color(0xCCFFFFFF),
                        ),
                      ),
                      if (asset.duration != null)
                        Positioned(
                          right: 6,
                          bottom: 5,
                          child: CcBadge(
                            asset.duration!,
                            fontSize: 9,
                            radius: 3,
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          ),
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
                    Text(asset.meta, style: CcType.nano),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
