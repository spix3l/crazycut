part of 'inspector_rows.dart';

/// Label · slider · value row (kept from the design for percentage controls).
class SliderRow extends StatelessWidget {
  const SliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.display,
    this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.labelWidth = 78,
  });

  final String label;

  /// 0..1 slider position.
  final double value;
  final String display;
  final ValueChanged<double>? onChanged;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            SizedBox(
              width: labelWidth,
              child: Text(label, style: CcType.small),
            ),
            Expanded(
              child: CcSlider(
                value: value.clamp(0, 1),
                onChanged: onChanged,
                onChangeStart: onChangeStart,
                onChangeEnd: onChangeEnd,
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 44,
              child: Text(
                display,
                textAlign: TextAlign.right,
                style: CcType.style(
                  size: 11,
                  weight: CcType.medium,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
