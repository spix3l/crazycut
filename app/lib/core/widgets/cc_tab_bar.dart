part of 'primitives.dart';

/// Underlined tab strip used by the inspector.
class CcTabBar extends StatelessWidget {
  const CcTabBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    this.onChanged,
    this.height = 37,
    this.fontSize = 12,
    this.horizontalPadding = 10,
    this.leadingInset = 14,
  });

  final List<String> tabs;
  final int selectedIndex;
  final ValueChanged<int>? onChanged;
  final double height;
  final double fontSize;
  final double horizontalPadding;
  final double leadingInset;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: const BoxDecoration(border: CcBorders.bottom),
      padding: EdgeInsets.only(left: leadingInset),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Expanded(
              child: CcTappable(
                onTap: onChanged == null ? null : () => onChanged!(i),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: i == selectedIndex ? CcColors.accent : const Color(0x00000000),
                        width: 2,
                      ),
                    ),
                  ),
                  child: Text(
                    tabs[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CcType.style(
                      size: fontSize,
                      weight: i == selectedIndex ? CcType.semibold : CcType.medium,
                      color: i == selectedIndex ? CcColors.textPrimary : CcColors.textTertiary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
