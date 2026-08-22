import 'dart:async';
import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../design/tokens.dart';

/// Icon wrapper so every call site is explicit about size and colour
/// (there is no `IconTheme` from a `MaterialApp` in this app).
class CcIcon extends StatelessWidget {
  const CcIcon(this.icon, {super.key, this.size = 14, this.color = CcColors.textSecondary});

  final IconData icon;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Icon(icon, size: size, color: color);
  }
}

/// Pointer affordance + press feedback without pulling in Material's `InkWell`.
class CcTappable extends StatefulWidget {
  const CcTappable({
    super.key,
    required this.child,
    this.onTap,
    this.cursor = SystemMouseCursors.click,
    this.hoverOpacity = 0.82,
    this.pressedOpacity = 0.65,
    this.builder,
  });

  final Widget child;
  final VoidCallback? onTap;
  final MouseCursor cursor;
  final double hoverOpacity;
  final double pressedOpacity;

  /// Optional hover-aware builder; when given it wins over the opacity fade.
  final Widget Function(BuildContext context, bool hovered, Widget child)? builder;

  @override
  State<CcTappable> createState() => _CcTappableState();
}

class _CcTappableState extends State<CcTappable> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    Widget child = widget.child;
    if (widget.builder != null) {
      child = widget.builder!(context, _hovered, child);
    } else {
      final opacity = _pressed
          ? widget.pressedOpacity
          : _hovered
          ? widget.hoverOpacity
          : 1.0;
      child = AnimatedOpacity(
        opacity: opacity,
        duration: const Duration(milliseconds: 90),
        child: child,
      );
    }
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: child,
      ),
    );
  }
}

enum CcButtonKind { primary, secondary, ghost }

/// Text button with optional leading icon — `New Project`, `Export`,
/// `Cancel`, `Create project`, `Add to queue`.
class CcButton extends StatelessWidget {
  const CcButton({
    super.key,
    required this.label,
    this.icon,
    this.kind = CcButtonKind.primary,
    this.onPressed,
    this.height = 34,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.radius = CcRadius.md,
  });

  final String label;
  final IconData? icon;
  final CcButtonKind kind;
  final VoidCallback? onPressed;
  final double height;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final isPrimary = kind == CcButtonKind.primary;
    final fg = isPrimary ? CcColors.onAccent : CcColors.textSecondary;
    return CcTappable(
      onTap: onPressed,
      child: Container(
        height: height,
        padding: padding,
        decoration: BoxDecoration(
          color: switch (kind) {
            CcButtonKind.primary => CcColors.accent,
            CcButtonKind.secondary => CcColors.elevated,
            CcButtonKind.ghost => null,
          },
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[CcIcon(icon!, size: 14, color: fg), const SizedBox(width: 6)],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.style(
                  size: 13,
                  weight: CcType.semibold,
                  color: fg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Square icon-only button, optionally toggled on (accent outline).
class CcIconButton extends StatelessWidget {
  const CcIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.size = 31,
    this.iconSize = 15,
    this.active = false,
    this.enabled = true,
    this.outlined = false,
    this.radius = CcRadius.sm,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final bool active;
  final bool enabled;
  final bool outlined;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: enabled ? onPressed : null,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? CcColors.elevated2 : (outlined ? CcColors.elevated : null),
          borderRadius: BorderRadius.circular(radius),
          border: active && outlined ? Border.all(color: CcColors.accent) : null,
        ),
        child: CcIcon(
          icon,
          size: iconSize,
          color: !enabled
              ? CcColors.textTertiary
              : active
              ? (outlined ? CcColors.accent : CcColors.textPrimary)
              : CcColors.textSecondary,
        ),
      ),
    );
  }
}

/// Read-only text field shell (`Search projects`, `Name`, `Filename`).
class CcTextField extends StatefulWidget {
  const CcTextField({
    super.key,
    this.value,
    this.placeholder,
    this.icon,
    this.trailing,
    this.height = 36,
    this.bordered = true,
    this.radius = CcRadius.md,
    this.controller,
    this.focusNode,
    this.autofocus = false,
    this.onSubmitted,
    this.onTapOutside,
  });

  final String? value;
  final String? placeholder;
  final IconData? icon;
  final Widget? trailing;
  final double height;
  final bool bordered;
  final double radius;

  /// Supplying a controller turns the field into a real text input; without
  /// one it stays a read-only shell.
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final TapRegionCallback? onTapOutside;

  @override
  State<CcTextField> createState() => _CcTextFieldState();
}

class _CcTextFieldState extends State<CcTextField> {
  FocusNode? _ownedFocus;

  FocusNode get _focus => widget.focusNode ?? (_ownedFocus ??= FocusNode());

  @override
  void dispose() {
    _ownedFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final controller = widget.controller;
    final height = widget.height;
    final icon = widget.icon;
    final trailing = widget.trailing;
    final hasValue = value != null && value.isNotEmpty;
    final textStyle = CcType.style(
      size: height <= 30 ? 12 : 13,
      color: hasValue || controller != null ? CcColors.textPrimary : CcColors.textTertiary,
    );
    return Container(
      height: height,
      padding: EdgeInsets.symmetric(horizontal: icon == null ? 12 : 10),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: BorderRadius.circular(widget.radius),
        border: widget.bordered ? Border.all(color: CcColors.borderStrong) : null,
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            CcIcon(icon, size: height <= 30 ? 13 : 14, color: CcColors.textTertiary),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: controller != null
                ? EditableText(
                    controller: controller,
                    focusNode: _focus,
                    autofocus: widget.autofocus,
                    style: textStyle,
                    cursorColor: CcColors.accent,
                    backgroundCursorColor: CcColors.elevated2,
                    selectionColor: CcColors.accent.withValues(alpha: 0.35),
                    onSubmitted: widget.onSubmitted,
                    onTapOutside: widget.onTapOutside,
                    maxLines: 1,
                  )
                : Text(
                    hasValue ? value : (widget.placeholder ?? ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textStyle,
                  ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }
}

/// App-native multi-line text input. Unlike Material's [TextField], this works
/// directly under CrazyCut's [WidgetsApp] root.
class CcMultilineTextField extends StatefulWidget {
  const CcMultilineTextField({
    super.key,
    required this.controller,
    this.placeholder,
    this.focusNode,
    this.autofocus = false,
    this.minLines = 1,
    this.maxLines = 3,
    this.onChanged,
  });

  final TextEditingController controller;
  final String? placeholder;
  final FocusNode? focusNode;
  final bool autofocus;
  final int minLines;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  @override
  State<CcMultilineTextField> createState() => _CcMultilineTextFieldState();
}

class _CcMultilineTextFieldState extends State<CcMultilineTextField> {
  FocusNode? _ownedFocus;

  FocusNode get _focus => widget.focusNode ?? (_ownedFocus ??= FocusNode());

  @override
  void dispose() {
    _ownedFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = CcType.style(size: 12, color: CcColors.textPrimary);
    return AnimatedBuilder(
      animation: _focus,
      builder: (context, _) => Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: CcDeco.input(focused: _focus.hasFocus),
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: widget.controller,
          builder: (context, value, _) => Stack(
            children: [
              if (value.text.isEmpty && widget.placeholder != null)
                IgnorePointer(
                  child: Text(
                    widget.placeholder!,
                    style: CcType.style(size: 12, color: CcColors.textTertiary),
                  ),
                ),
              EditableText(
                controller: widget.controller,
                focusNode: _focus,
                autofocus: widget.autofocus,
                style: style,
                cursorColor: CcColors.accent,
                backgroundCursorColor: CcColors.elevated2,
                selectionColor: CcColors.accent.withValues(alpha: 0.35),
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                minLines: widget.minLines,
                maxLines: widget.maxLines,
                onTapOutside: (_) => _focus.unfocus(
                  disposition: UnfocusDisposition.previouslyFocusedChild,
                ),
                onChanged: widget.onChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline accent link used inside fields (`Change`, `Browse`).
class CcLink extends StatelessWidget {
  const CcLink(this.label, {super.key, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Text(
        label,
        style: CcType.style(size: 12, weight: CcType.medium, color: CcColors.accent),
      ),
    );
  }
}

/// Compact dropdown pill (`Last opened`, `Auto`, `Fit`, `Full`).
class CcDropdown extends StatelessWidget {
  const CcDropdown({
    super.key,
    required this.value,
    this.onTap,
    this.height = 32,
    this.width,
    this.fontSize = 13,
    this.bordered = false,
    this.radius = CcRadius.sm,
  });

  final String value;
  final VoidCallback? onTap;
  final double height;
  final double? width;
  final double fontSize;
  final bool bordered;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Container(
        height: height,
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: CcColors.elevated,
          borderRadius: BorderRadius.circular(radius),
          border: bordered ? Border.all(color: CcColors.borderStrong) : null,
        ),
        child: Row(
          mainAxisSize: width == null ? MainAxisSize.min : MainAxisSize.max,
          children: [
            Expanded(
              flex: width == null ? 0 : 1,
              child: Text(
                value,
                style: CcType.style(
                  size: fontSize,
                  color: bordered ? CcColors.textPrimary : CcColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            CcIcon(
              LucideIcons.chevronDown,
              size: fontSize,
              color: bordered ? CcColors.textTertiary : CcColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// Checkbox in the export options row / effect stack header.
class CcCheckbox extends StatelessWidget {
  const CcCheckbox({super.key, required this.checked, this.size = 15, this.onTap});

  final bool checked;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: checked ? CcColors.accent : CcColors.elevated,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: checked ? CcColors.accent : CcColors.borderStrong),
        ),
        child: checked
            ? CcIcon(LucideIcons.check, size: size - 4, color: CcColors.onAccent)
            : null,
      ),
    );
  }
}

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
          onPointerDown:
              onChanged == null ? null : (_) => onChangeStart?.call(),
          onPointerUp: onChanged == null ? null : (_) => onChangeEnd?.call(),
          onPointerCancel:
              onChanged == null ? null : (_) => onChangeEnd?.call(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: onChanged == null ? null : (d) => emit(d.localPosition),
            onHorizontalDragUpdate:
                onChanged == null ? null : (d) => emit(d.localPosition),
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
                        color:
                            i == selectedIndex
                                ? CcColors.accent
                                : const Color(0x00000000),
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
                      weight:
                          i == selectedIndex
                              ? CcType.semibold
                              : CcType.medium,
                      color:
                          i == selectedIndex
                              ? CcColors.textPrimary
                              : CcColors.textTertiary,
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

/// Rounded dark pill used for badges over thumbnails.
class CcBadge extends StatelessWidget {
  const CcBadge(
    this.label, {
    super.key,
    this.fontSize = 11,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    this.radius = CcRadius.sm,
  });

  final String label;
  final double fontSize;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: CcColors.badgeBg,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(
        label,
        style: CcType.style(size: fontSize, weight: CcType.medium),
      ),
    );
  }
}

/// The 1px vertical hairline used between toolbar groups.
class CcDivider extends StatelessWidget {
  const CcDivider({super.key, this.height = 22});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: height, color: CcColors.borderStrong);
  }
}

/// One row of a [CcMenu].
class CcMenuItem {
  const CcMenuItem(
    this.label, {
    this.onTap,
    this.icon,
    this.shortcut,
    this.danger = false,
    this.checked,
    this.separatorBefore = false,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final String? shortcut;
  final bool danger;

  /// Non-null renders a check column (toggle items).
  final bool? checked;
  final bool separatorBefore;
}

/// Floating verb list used by context menus and the track menu. Disabled rows
/// stay visible so the menu shape does not jump between targets.
class CcMenu extends StatelessWidget {
  const CcMenu({
    super.key,
    required this.items,
    this.onSelected,
    this.width = 210,
    this.maxHeight,
  });

  final List<CcMenuItem> items;
  final VoidCallback? onSelected;
  final double width;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      constraints:
          maxHeight == null ? null : BoxConstraints(maxHeight: maxHeight!),
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: CcRadius.brMd,
        border: CcBorders.allStrong,
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 20, offset: Offset(0, 8)),
        ],
      ),
      child: SingleChildScrollView(
        primary: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in items) ...[
              if (item.separatorBefore)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: SizedBox(
                    height: 1,
                    child: ColoredBox(color: CcColors.border),
                  ),
                ),
              CcTappable(
                onTap:
                    item.onTap == null
                        ? null
                        : () {
                          onSelected?.call();
                          item.onTap!();
                        },
                builder:
                    (context, hovered, _) => Container(
                      height: 28,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      color:
                          hovered && item.onTap != null
                              ? CcColors.elevated2
                              : const Color(0x00000000),
                      child: Row(
                        children: [
                          if (item.checked != null) ...[
                            CcIcon(
                              item.checked!
                                  ? LucideIcons.check
                                  : LucideIcons.minus,
                              size: 12,
                              color:
                                  item.checked!
                                      ? CcColors.accent
                                      : CcColors.textTertiary,
                            ),
                            const SizedBox(width: 8),
                          ] else if (item.icon != null) ...[
                            CcIcon(
                              item.icon!,
                              size: 12,
                              color: CcColors.textSecondary,
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              item.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CcType.style(
                                size: 12,
                                color:
                                    item.onTap == null
                                        ? CcColors.textTertiary
                                        : item.danger
                                        ? CcColors.error
                                        : CcColors.textPrimary,
                              ),
                            ),
                          ),
                          if (item.shortcut != null)
                            Text(item.shortcut!, style: CcType.nano),
                        ],
                      ),
                    ),
                child: const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Opens a [CcMenu] at a global position (right-click menus).
void showCcMenu(BuildContext context, Offset globalPosition, List<CcMenuItem> items) {
  final overlay = Overlay.of(context);
  final overlayBox = overlay.context.findRenderObject() as RenderBox?;
  if (overlayBox == null) return;
  late OverlayEntry entry;
  void close() => entry.remove();
  const edgeMargin = 20.0;
  const preferredMenuWidth = 210.0;
  final separatorHeight = items.where((item) => item.separatorBefore).length * 9.0;
  // Ten pixels of explicit vertical padding plus the one-pixel border on each
  // edge. Keeping this equal to CcMenu's real height prevents bottom clipping.
  final estimatedHeight = items.length * 28.0 + separatorHeight + 12;
  final requested = overlayBox.globalToLocal(globalPosition);
  final horizontalMargin =
      overlayBox.size.width < edgeMargin * 2
          ? overlayBox.size.width / 2
          : edgeMargin;
  final verticalMargin =
      overlayBox.size.height < edgeMargin * 2
          ? overlayBox.size.height / 2
          : edgeMargin;
  final availableWidth = (overlayBox.size.width - horizontalMargin * 2).clamp(
    0.0,
    double.infinity,
  );
  final availableHeight = (overlayBox.size.height - verticalMargin * 2).clamp(
    0.0,
    double.infinity,
  );
  final menuWidth = preferredMenuWidth.clamp(0.0, availableWidth);
  final menuHeight = estimatedHeight.clamp(0.0, availableHeight);
  final dx = requested.dx.clamp(
    horizontalMargin,
    overlayBox.size.width - menuWidth - horizontalMargin,
  );
  final dy = requested.dy.clamp(
    verticalMargin,
    overlayBox.size.height - menuHeight - verticalMargin,
  );
  entry = OverlayEntry(
    builder: (context) => Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: close),
        ),
        Positioned(
          left: dx,
          top: dy,
          child: CcMenu(
            items: items,
            onSelected: close,
            width: menuWidth,
            maxHeight: availableHeight,
          ),
        ),
      ],
    ),
  );
  overlay.insert(entry);
}

/// Opens a [CcMenu] from the lower-left corner of [anchorContext].
///
/// Use this for button-triggered menus. Pointer-triggered context menus should
/// continue to call [showCcMenu] with the pointer's global position.
void showCcMenuBelow(BuildContext anchorContext, List<CcMenuItem> items) {
  final anchor = anchorContext.findRenderObject() as RenderBox?;
  if (anchor == null || !anchor.attached) return;
  final position = anchor.localToGlobal(Offset(0, anchor.size.height + 4));
  showCcMenu(anchorContext, position, items);
}

/// Hover tooltip. Material's `Tooltip` is off-limits here, and the timeline
/// leans on tooltips for the trim/shortcut hints, so this is the smallest
/// overlay-based stand-in that behaves.
class CcTooltip extends StatefulWidget {
  const CcTooltip({
    super.key,
    required this.message,
    required this.child,
    this.delay = const Duration(milliseconds: 450),
  });

  final String message;
  final Widget child;
  final Duration delay;

  @override
  State<CcTooltip> createState() => _CcTooltipState();
}

class _CcTooltipState extends State<CcTooltip> {
  OverlayEntry? _entry;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _remove();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(widget.delay, _show);
  }

  void _show() {
    if (_entry != null || !mounted || widget.message.isEmpty) return;
    final target = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (target == null || overlayBox == null || !target.attached) return;

    const screenMargin = 8.0;
    const gap = 6.0;
    const horizontalPadding = 16.0;
    const verticalPadding = 10.0;
    final maxBubbleWidth = overlayBox.size.width < 276
        ? overlayBox.size.width - screenMargin * 2
        : 260.0;
    final textPainter = TextPainter(
      text: TextSpan(text: widget.message, style: CcType.nano),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxBubbleWidth - horizontalPadding);
    final bubbleWidth = textPainter.width + horizontalPadding;
    final bubbleHeight = textPainter.height + verticalPadding;
    final targetOrigin = target.localToGlobal(Offset.zero, ancestor: overlayBox);
    final targetRect = targetOrigin & target.size;
    final left = (targetRect.center.dx - bubbleWidth / 2).clamp(
      screenMargin,
      overlayBox.size.width - bubbleWidth - screenMargin,
    );
    final above = targetRect.top - bubbleHeight - gap;
    final top = (above >= screenMargin ? above : targetRect.bottom + gap).clamp(
      screenMargin,
      overlayBox.size.height - bubbleHeight - screenMargin,
    );

    _entry = OverlayEntry(
      builder: (context) => Positioned(
        left: left,
        top: top,
        width: bubbleWidth,
        child: IgnorePointer(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: CcColors.elevated2,
              borderRadius: CcRadius.brSm,
              border: CcBorders.allStrong,
            ),
            child: Text(widget.message, style: CcType.nano),
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  void _remove() {
    _timer?.cancel();
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _schedule(),
      onExit: (_) => _remove(),
      child: widget.child,
    );
  }
}
