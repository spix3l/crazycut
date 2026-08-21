import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../models/editor_models.dart';

/// Left gutter row of a timeline track: kind icon, name, visibility + lock.
class TrackHeaderTile extends StatelessWidget {
  const TrackHeaderTile({super.key, required this.track});

  static const double width = 160;

  final TimelineTrack track;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: track.height,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: CcColors.elevated,
        border: Border(
          right: BorderSide(color: CcColors.border),
          bottom: BorderSide(color: CcColors.border),
        ),
      ),
      child: Row(
        children: [
          CcIcon(
            track.kind == TrackKind.video ? LucideIcons.video : LucideIcons.audioWaveform,
            size: 13,
          ),
          const SizedBox(width: 7),
          Text(track.name, style: CcType.style(size: 12, weight: CcType.semibold)),
          const Spacer(),
          const CcIcon(LucideIcons.eye, size: 12, color: CcColors.textTertiary),
          const SizedBox(width: 6),
          const CcIcon(LucideIcons.lock, size: 12, color: CcColors.textTertiary),
        ],
      ),
    );
  }
}
