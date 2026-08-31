part of 'primitives.dart';

/// Segmented control (`Start / Center / End`, tool picker, view toggle).
class CcSegmented extends StatelessWidget {
  const CcSegmented({
    super.key,
    required this.children,
    required this.selectedIndex,
    this.onChanged,
    this.height = 29,
    this.padding = 2,
    this.expand = false,
  });

  final List<Widget> children;
  final int selectedIndex;
  final ValueChanged<int>? onChanged;
  final double height;
  final double padding;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    Widget segment(int i) {
      final selected = i == selectedIndex;
      return CcTappable(
        onTap: onChanged == null ? null : () => onChanged!(i),
        child: Container(
          height: height - padding * 2,
          alignment: Alignment.center,
          padding: expand ? null : const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? CcColors.elevated2 : CcColors.elevated,
            borderRadius: CcRadius.brSm,
          ),
          child: children[i],
        ),
      );
    }

    return Container(
      height: height,
      padding: EdgeInsets.all(padding),
      decoration: const BoxDecoration(color: CcColors.elevated, borderRadius: CcRadius.brSm),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++)
            expand ? Expanded(child: segment(i)) : segment(i),
        ],
      ),
    );
  }
}
