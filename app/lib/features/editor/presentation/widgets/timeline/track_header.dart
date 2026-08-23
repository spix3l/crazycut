import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/project.dart';

/// Left gutter row of a timeline track: name (double-click to rename), the
/// mute/solo/hide/lock toggles, height cycling and reordering (TIM-1/2).
class TrackHeaderTile extends StatefulWidget {
  const TrackHeaderTile({
    super.key,
    required this.track,
    this.height,
    this.selected = false,
    this.dragHandle,
    this.onSelect,
    this.onRename,
    this.onToggleMute,
    this.onToggleSolo,
    this.onToggleHidden,
    this.onToggleLock,
    this.onCycleHeight,
    this.onReorder,
    this.onRemove,
  });

  static const double width = 160;

  final Track track;

  /// Displayed lane height. Defaults to the track's authored height; the
  /// timeline shrinks lanes when zoomed out, and the gutter has to track
  /// that or the two columns drift apart.
  final double? height;
  final bool selected;
  final Widget? dragHandle;
  final VoidCallback? onSelect;
  final ValueChanged<String>? onRename;
  final VoidCallback? onToggleMute;
  final VoidCallback? onToggleSolo;
  final VoidCallback? onToggleHidden;
  final VoidCallback? onToggleLock;
  final VoidCallback? onCycleHeight;

  /// Negative moves the track up a lane, positive down.
  final ValueChanged<int>? onReorder;
  final VoidCallback? onRemove;

  @override
  State<TrackHeaderTile> createState() => _TrackHeaderTileState();
}

class _TrackHeaderTileState extends State<TrackHeaderTile> {
  TextEditingController? _rename;
  final _focus = FocusNode();

  @override
  void dispose() {
    _rename?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startRename() {
    setState(() => _rename = TextEditingController(text: widget.track.name));
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _commitRename() {
    final value = _rename?.text ?? '';
    widget.onRename?.call(value);
    setState(() {
      _rename?.dispose();
      _rename = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final displayHeight = widget.height ?? track.height.toDouble();
    final compact = displayHeight <= 56;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onSelect,
      onDoubleTap: widget.onRename == null ? null : _startRename,
      child: Container(
        height: displayHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: widget.selected ? CcColors.elevated2 : CcColors.elevated,
          border: const Border(
            right: BorderSide(color: CcColors.border),
            bottom: BorderSide(color: CcColors.border),
          ),
        ),
        child: Row(
          children: [
            if (widget.dragHandle != null) ...[
              widget.dragHandle!,
              const SizedBox(width: 6)
            ],
            CcIcon(
              track.isVideo ? LucideIcons.video : LucideIcons.audioWaveform,
              size: 13,
              color: track.lock ? CcColors.textTertiary : CcColors.textPrimary,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: _rename != null
                  ? CcTextField(
                      controller: _rename,
                      focusNode: _focus,
                      height: 22,
                      bordered: false,
                      radius: CcRadius.sm,
                      onSubmitted: (_) => _commitRename(),
                    )
                  : Text(
                      track.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CcType.style(size: 12, weight: CcType.semibold),
                    ),
            ),
            if (!compact) ...[
              _Toggle(
                icon: track.isVideo ? LucideIcons.eye : LucideIcons.volume2,
                crossedIcon:
                    track.isVideo ? LucideIcons.eyeOff : LucideIcons.volumeOff,
                active: track.isVideo ? !track.hidden : !track.mute,
                onTap:
                    track.isVideo ? widget.onToggleHidden : widget.onToggleMute,
              ),
              const SizedBox(width: 4),
              if (!track.isVideo)
                _Toggle(
                  icon: LucideIcons.headphones,
                  crossedIcon: LucideIcons.headphones,
                  active: track.solo,
                  highlight: true,
                  onTap: widget.onToggleSolo,
                ),
              if (!track.isVideo) const SizedBox(width: 4),
              _Toggle(
                icon: LucideIcons.lockOpen,
                crossedIcon: LucideIcons.lock,
                active: !track.lock,
                onTap: widget.onToggleLock,
              ),
              const SizedBox(width: 4),
            ],
            _TrackMenu(
              onCycleHeight: widget.onCycleHeight,
              onReorder: widget.onReorder,
              onRemove: widget.onRemove,
              onRename: widget.onRename == null ? null : _startRename,
            ),
          ],
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.icon,
    required this.crossedIcon,
    required this.active,
    this.highlight = false,
    this.onTap,
  });

  final IconData icon;
  final IconData crossedIcon;
  final bool active;
  final bool highlight;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: CcIcon(
        active ? icon : crossedIcon,
        size: 12,
        color: highlight
            ? (active ? CcColors.accent : CcColors.textTertiary)
            : (active ? CcColors.textTertiary : CcColors.warning),
      ),
    );
  }
}

/// Track verbs that do not deserve a permanent button.
class _TrackMenu extends StatefulWidget {
  const _TrackMenu(
      {this.onCycleHeight, this.onReorder, this.onRemove, this.onRename});

  final VoidCallback? onCycleHeight;
  final ValueChanged<int>? onReorder;
  final VoidCallback? onRemove;
  final VoidCallback? onRename;

  @override
  State<_TrackMenu> createState() => _TrackMenuState();
}

class _TrackMenuState extends State<_TrackMenu> {
  void _open(BuildContext anchorContext) {
    showCcMenu(anchorContext, [
      CcMenuItem('Rename', onTap: widget.onRename),
      CcMenuItem('Cycle height', onTap: widget.onCycleHeight),
      CcMenuItem(
        'Move up',
        onTap:
            widget.onReorder == null ? null : () => widget.onReorder!(-1),
      ),
      CcMenuItem(
        'Move down',
        onTap: widget.onReorder == null ? null : () => widget.onReorder!(1),
      ),
      CcMenuItem('Delete track', danger: true, onTap: widget.onRemove),
    ]);
  }

  @override
  Widget build(BuildContext context) => CcTappable(
    onTap: () => _open(context),
    child: const CcIcon(
      LucideIcons.ellipsis,
      size: 13,
      color: CcColors.textTertiary,
    ),
  );
}
