part of 'primitives.dart';

/// The 1px vertical hairline used between toolbar groups.
class CcDivider extends StatelessWidget {
  const CcDivider({super.key, this.height = 22});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: height, color: CcColors.borderStrong);
  }
}
