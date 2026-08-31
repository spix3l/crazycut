part of 'primitives.dart';

/// Thin accent-filled track with a round handle. Presentation only.
class CcSlider extends StatelessWidget {
  const CcSlider({
    super.key,
    required this.value,
    this.trackHeight = 4,
    this.handleSize = 10,
    this.fillColor = CcColors.accent,
    this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });

  /// 0..1
  final double value;
  final double trackHeight;
  final double handleSize;
  final Color fillColor;

  /// Null keeps the slider decorative (the design has a few of those).
  final ValueChanged<double>? onChanged;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final filled = (width * value.clamp(0, 1));
        void emit(Offset local) => onChanged?.call((local.dx / width).clamp(0.0, 1.0));
        return Listener(
          onPointerDown: onChanged == null ? null : (_) => onChangeStart?.call(),
          onPointerUp: onChanged == null ? null : (_) => onChangeEnd?.call(),
          onPointerCancel: onChanged == null ? null : (_) => onChangeEnd?.call(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: onChanged == null ? null : (d) => emit(d.localPosition),
            onHorizontalDragUpdate: onChanged == null ? null : (d) => emit(d.localPosition),
            child: SizedBox(
              height: handleSize,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: trackHeight,
                    decoration: BoxDecoration(
                      color: CcColors.elevated2,
                      borderRadius: BorderRadius.circular(trackHeight / 2),
                    ),
                  ),
                  Container(
                    width: filled,
                    height: trackHeight,
                    decoration: BoxDecoration(
                      color: fillColor,
                      borderRadius: BorderRadius.circular(trackHeight / 2),
                    ),
                  ),
                  Positioned(
                    left: (filled - handleSize / 2).clamp(0.0, width - handleSize),
                    child: Container(
                      width: handleSize,
                      height: handleSize,
                      decoration: const BoxDecoration(
                        color: CcColors.textPrimary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
