part of 'timeline_clip_tile.dart';

/// The hourglass badge straddling a cut where a transition lives.
class TransitionBadge extends StatelessWidget {
  const TransitionBadge({
    super.key,
    required this.height,
    this.width = 24,
    this.selected = false,
  });

  final double height;
  final double width;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: MediaKind.video.plate,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(
          color: selected ? CcColors.accent : const Color(0x30FFFFFF),
          width: selected ? 2 : 1,
        ),
      ),
      child: const CcIcon(
        LucideIcons.hourglass,
        size: 12,
        color: Color(0xDDFFFFFF),
      ),
    );
  }
}

/// Height of the keyframe ribbon drawn along the top of an animated clip.
const double kKeyframeRibbonHeight = 11;

/// Below this lane height the ribbon would crowd the name plate off the tile,
/// so an animated clip shows nothing rather than an illegible smear.
const double kKeyframeRibbonMinTrackHeight = 34;

/// Height of the stripe marking where a track stopped being trustworthy.
const double kTrackConfidenceStripeHeight = 3;
