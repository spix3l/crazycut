part of 'cc_dialog.dart';

/// Modal shell shared by "New project" and "Export": scrim, elevated panel,
/// bordered header with a close affordance, scrollable body and a footer.
class CcDialogShell extends StatelessWidget {
  const CcDialogShell({
    super.key,
    required this.title,
    required this.width,
    required this.sections,
    required this.actions,
    this.onClose,
    this.bodyPadding = const EdgeInsets.all(24),
    this.gap = 20,
  });

  final String title;
  final double width;
  final List<Widget> sections;
  final List<Widget> actions;
  final VoidCallback? onClose;
  final EdgeInsets bodyPadding;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: CcColors.panel,
        borderRadius: CcRadius.brLg,
        border: CcBorders.allStrong,
        boxShadow: CcDeco.dialogShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 59,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: const BoxDecoration(border: CcBorders.bottom),
            child: Row(
              children: [
                Expanded(child: Text(title, style: CcType.dialogTitle)),
                const SizedBox(width: 12),
                CcTappable(onTap: onClose, child: const CcIcon(LucideIcons.x, size: 18)),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: bodyPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < sections.length; i++) ...[
                    if (i > 0) SizedBox(height: gap),
                    sections[i],
                  ],
                ],
              ),
            ),
          ),
          Container(
            height: 66,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: const BoxDecoration(border: CcBorders.top),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  actions[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
