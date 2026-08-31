part of 'primitives.dart';

/// Uppercase section header inside inspector panels.
class CcSectionHeader extends StatelessWidget {
  const CcSectionHeader(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: CcType.sectionHeader),
        const Spacer(),
        ?trailing,
      ],
    );
  }
}
