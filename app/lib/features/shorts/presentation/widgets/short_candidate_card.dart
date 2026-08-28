import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../data/media_cache.dart';
import '../../../../data/project.dart';
import '../../../../state/shorts_service.dart';

enum ShortCardState { pending, accepted, rejected }

/// One proposed moment (SHT-8, SHT-9).
///
/// Deliberately the same card metaphor as the export queue: this is the same
/// kind of object — a queue of proposed work — and inventing a second visual
/// language for it would just be noise.
class ShortCandidateCard extends StatefulWidget {
  const ShortCandidateCard({
    super.key,
    required this.candidate,
    required this.state,
    required this.onPreview,
    required this.onAccept,
    required this.onReject,
    required this.onNudgeStart,
    required this.onNudgeEnd,
    this.asset,
  });

  final ShortCandidate candidate;
  final MediaAsset? asset;
  final ShortCardState state;
  final VoidCallback onPreview;
  final Future<void> Function() onAccept;
  final VoidCallback onReject;
  final ValueChanged<double> onNudgeStart;
  final ValueChanged<double> onNudgeEnd;

  @override
  State<ShortCandidateCard> createState() => _ShortCandidateCardState();
}

class _ShortCandidateCardState extends State<ShortCandidateCard> {
  Uint8List? _thumb;

  @override
  void initState() {
    super.initState();
    _loadThumb();
  }

  @override
  void didUpdateWidget(ShortCandidateCard old) {
    super.didUpdateWidget(old);
    if (old.candidate.startSec != widget.candidate.startSec) _loadThumb();
  }

  Future<void> _loadThumb() async {
    final asset = widget.asset;
    if (asset == null) return;
    final midpoint =
        widget.candidate.startSec + widget.candidate.durationSec / 2;
    final bytes = await MediaCache.instance.thumb(asset, midpoint, width: 160);
    if (mounted) setState(() => _thumb = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.candidate;
    final settled = widget.state != ShortCardState.pending;

    return Opacity(
      opacity: widget.state == ShortCardState.rejected ? 0.45 : 1,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: CcColors.elevated,
          borderRadius: CcRadius.brMd,
          border: Border.all(
            color:
                widget.state == ShortCardState.accepted
                    ? CcColors.success
                    : CcColors.border,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Thumb(bytes: _thumb, onTap: widget.onPreview),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          c.title.isEmpty ? 'Untitled moment' : c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CcType.style(
                            size: 13,
                            weight: CcType.semibold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      CcBadge(c.confidenceLabel),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_stamp(c.startSec)} – ${_stamp(c.endSec)} · '
                    '${c.durationSec.round()}s',
                    style: CcType.style(size: 11, color: CcColors.textTertiary),
                  ),
                  if (c.hook.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      '“${c.hook}”',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: CcType.style(
                        size: 12,
                        color: CcColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (widget.state == ShortCardState.accepted)
                    Row(
                      children: [
                        const CcIcon(
                          LucideIcons.circleCheck,
                          size: 14,
                          color: CcColors.success,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Project created',
                          style: CcType.style(
                            size: 12,
                            color: CcColors.success,
                          ),
                        ),
                      ],
                    )
                  else if (widget.state == ShortCardState.rejected)
                    Text(
                      'Rejected',
                      style: CcType.style(
                        size: 12,
                        color: CcColors.textTertiary,
                      ),
                    )
                  else ...[
                    Row(
                      children: [
                        CcButton(
                          label: 'Play preview',
                          icon: LucideIcons.play,
                          kind: CcButtonKind.secondary,
                          height: 32,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          onPressed: widget.onPreview,
                        ),
                        const SizedBox(width: 10),
                        _NudgeGroup(
                          label: 'In',
                          onEarlier: () => widget.onNudgeStart(-1),
                          onLater: () => widget.onNudgeStart(1),
                        ),
                        const SizedBox(width: 10),
                        _NudgeGroup(
                          label: 'Out',
                          onEarlier: () => widget.onNudgeEnd(-1),
                          onLater: () => widget.onNudgeEnd(1),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        CcButton(
                          label: 'Reject',
                          kind: CcButtonKind.ghost,
                          height: 30,
                          onPressed: settled ? null : widget.onReject,
                        ),
                        const SizedBox(width: 6),
                        CcButton(
                          label: 'Make project',
                          height: 30,
                          onPressed: settled ? null : () => widget.onAccept(),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _stamp(double seconds) {
    final total = seconds.round();
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({this.bytes, this.onTap});
  final Uint8List? bytes;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: CcRadius.brSm,
        child: Container(
          width: 96,
          height: 128,
          color: CcColors.panel,
          child:
              bytes == null
                  ? const Center(
                    child: CcIcon(
                      LucideIcons.image,
                      size: 16,
                      color: CcColors.textTertiary,
                    ),
                  )
                  // Cropped to 9:16 the same way the exported short will be, so the
                  // card previews the real framing rather than the source.
                  : Image.memory(bytes!, fit: BoxFit.cover),
        ),
      ),
    );
  }
}

class _NudgeGroup extends StatelessWidget {
  const _NudgeGroup({
    required this.label,
    required this.onEarlier,
    required this.onLater,
  });

  final String label;
  final VoidCallback onEarlier;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: CcType.style(size: 11, color: CcColors.textTertiary),
        ),
        const SizedBox(width: 4),
        CcTooltip(
          message: '$label one second earlier',
          child: CcIconButton(
            icon: LucideIcons.chevronLeft,
            size: 26,
            iconSize: 13,
            onPressed: onEarlier,
          ),
        ),
        CcTooltip(
          message: '$label one second later',
          child: CcIconButton(
            icon: LucideIcons.chevronRight,
            size: 26,
            iconSize: 13,
            onPressed: onLater,
          ),
        ),
      ],
    );
  }
}
