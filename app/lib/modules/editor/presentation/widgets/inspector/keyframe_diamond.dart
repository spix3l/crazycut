part of 'inspector_effects_tab.dart';

/// The ◆ toggle (KEY-4).
class KeyframeDiamond extends StatelessWidget {
  const KeyframeDiamond({
    super.key,
    required this.animated,
    required this.atCurrentTime,
    this.onTap,
    this.onContextMenu,
  });

  final bool animated;
  final bool atCurrentTime;
  final VoidCallback? onTap;

  /// Anchors the right-click menu to the diamond itself.
  final ValueChanged<BuildContext>? onContextMenu;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder:
          (diamondContext) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapDown:
                onContextMenu == null
                    ? null
                    : (_) => onContextMenu!(diamondContext),
            child: CcTooltip(
              message:
                  atCurrentTime
                      ? 'Keyframe at playhead · right-click for options'
                      : animated
                      ? 'Animated · click to add a keyframe here'
                      : 'Add keyframe at playhead',
              child: CcTappable(
                onTap: onTap,
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: Center(
                    child: Transform.rotate(
                      angle: 3.14159 / 4,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color:
                              atCurrentTime
                                  ? CcColors.accent
                                  : CcColors.elevated2,
                          border: Border.all(
                            color:
                                animated || atCurrentTime
                                    ? CcColors.accent
                                    : CcColors.borderStrong,
                          ),
                          borderRadius: BorderRadius.circular(1.5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
    );
  }
}
