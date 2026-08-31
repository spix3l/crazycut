part of 'inspector_panel.dart';

/// Tabs that have no controls yet, kept honest about why.
class PlaceholderTab extends StatelessWidget {
  const PlaceholderTab({super.key, required this.name, required this.note});

  final String name;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CcSectionHeader(name.toUpperCase()),
          const SizedBox(height: 12),
          Text(
            note,
            style: CcType.style(
              size: 11,
              color: CcColors.textTertiary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
