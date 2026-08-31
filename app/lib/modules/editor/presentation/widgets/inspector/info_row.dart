part of 'inspector_rows.dart';

/// Label + value row for read-only facts.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key});

  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        spacing: 16,
        children: [Text(label, style: CcType.small), Expanded(child: value)],
      ),
    );
  }
}
