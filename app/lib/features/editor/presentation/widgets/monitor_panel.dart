import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';

/// Centre column: overlay toggles, the program monitor and the transport bar.
class MonitorPanel extends StatelessWidget {
  const MonitorPanel({
    super.key,
    this.empty = false,
    this.currentTimecode = '00:00:12:04',
    this.totalTimecode = '00:03:45:00',
    this.frame,
    this.playing = false,
    this.onPlayPause,
    this.onStepBack,
    this.onStepForward,
    this.caption,
  });

  final bool empty;
  final String currentTimecode;
  final String totalTimecode;

  /// Encoded frame under the playhead; null falls back to the placeholder.
  final Uint8List? frame;
  final bool playing;
  final VoidCallback? onPlayPause;
  final VoidCallback? onStepBack;
  final VoidCallback? onStepForward;

  /// Selected caption drawn over the frame, when there is one.
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: CcColors.bg,
      child: Column(
        children: [
          const _MonitorToolbar(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Center(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: switch ((empty, frame)) {
                    (true, _) => const _EmptyPreview(),
                    (false, final Uint8List bytes) => _FramePreview(
                      bytes: bytes,
                      caption: caption,
                    ),
                    _ => const _EmptyPreview(message: 'No frame under the playhead'),
                  },
                ),
              ),
            ),
          ),
          _TransportBar(
            empty: empty,
            playing: playing,
            currentTimecode: empty ? '00:00:00:00' : currentTimecode,
            totalTimecode: empty ? '00:00:00:00' : totalTimecode,
            onPlayPause: onPlayPause,
            onStepBack: onStepBack,
            onStepForward: onStepForward,
          ),
        ],
      ),
    );
  }
}

class _MonitorToolbar extends StatelessWidget {
  const _MonitorToolbar();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const CcIcon(LucideIcons.squareDashed, size: 15, color: CcColors.textTertiary),
            const SizedBox(width: 14),
            const CcIcon(LucideIcons.grid3x3, size: 15, color: CcColors.textTertiary),
            const Spacer(),
            const CcDropdown(value: 'Fit', height: 23, fontSize: 11),
            const SizedBox(width: 8),
            const CcDropdown(value: 'Full', height: 23, fontSize: 11),
          ],
        ),
      ),
    );
  }
}

class _EmptyPreview extends StatelessWidget {
  const _EmptyPreview({this.message = 'Nothing on the timeline yet'});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(color: Color(0xFF000000), border: CcBorders.all),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CcIcon(LucideIcons.film, size: 28, color: CcColors.textTertiary),
          const SizedBox(height: 10),
          Text(message, style: CcType.style(size: 13, color: CcColors.textTertiary)),
        ],
      ),
    );
  }
}

/// The real decoded frame, with the selected caption drawn over it.
class _FramePreview extends StatelessWidget {
  const _FramePreview({required this.bytes, this.caption});

  final Uint8List bytes;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF000000),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
          if (caption != null)
            Align(
              alignment: const Alignment(0, 0.62),
              child: _SelectedCaption(text: caption!),
            ),
        ],
      ),
    );
  }
}

class _SelectedCaption extends StatelessWidget {
  const _SelectedCaption({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0x90000000),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: CcColors.accent, width: 1.5),
          ),
          child: Text(
            text,
            style: CcType.style(size: 20, weight: CcType.bold, color: const Color(0xFFFFFFFF)),
          ),
        ),
        const Positioned(left: -4, top: -4, child: _Handle()),
        const Positioned(right: -4, top: -4, child: _Handle()),
        const Positioned(left: -4, bottom: -4, child: _Handle()),
        const Positioned(right: -4, bottom: -4, child: _Handle()),
      ],
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: CcColors.accent,
        borderRadius: BorderRadius.circular(1),
        border: Border.all(color: const Color(0xFFFFFFFF)),
      ),
    );
  }
}

class _TransportBar extends StatelessWidget {
  const _TransportBar({
    required this.empty,
    required this.playing,
    required this.currentTimecode,
    required this.totalTimecode,
    this.onPlayPause,
    this.onStepBack,
    this.onStepForward,
  });

  final bool empty;
  final bool playing;
  final String currentTimecode;
  final String totalTimecode;
  final VoidCallback? onPlayPause;
  final VoidCallback? onStepBack;
  final VoidCallback? onStepForward;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(currentTimecode, style: CcType.bodyStrong),
                  const SizedBox(width: 4),
                  Text('/', style: CcType.style(size: 13, color: CcColors.textTertiary)),
                  const SizedBox(width: 4),
                  Text(
                    totalTimecode,
                    style: CcType.style(size: 13, color: CcColors.textTertiary),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CcTappable(
                  onTap: onStepBack,
                  child: const CcIcon(LucideIcons.skipBack, size: 16),
                ),
                const SizedBox(width: 18),
                CcTappable(
                  onTap: onPlayPause,
                  child: Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: empty ? CcColors.elevated2 : CcColors.accent,
                      shape: BoxShape.circle,
                    ),
                    child: CcIcon(
                      playing ? LucideIcons.pause : LucideIcons.play,
                      size: 15,
                      color: CcColors.onAccent,
                    ),
                  ),
                ),
                const SizedBox(width: 18),
                CcTappable(
                  onTap: onStepForward,
                  child: const CcIcon(LucideIcons.skipForward, size: 16),
                ),
                const SizedBox(width: 18),
                const CcIcon(LucideIcons.repeat, size: 15, color: CcColors.textTertiary),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: _MasterMeter(empty: empty || !playing),
            ),
          ],
        ),
      ),
    );
  }
}

/// Eight-bar output meter; flat when nothing is playing.
class _MasterMeter extends StatelessWidget {
  const _MasterMeter({required this.empty});

  static const List<double> _levels = [10, 18, 26, 20, 14, 22, 30, 16];

  final bool empty;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < _levels.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Container(
              width: 4,
              height: empty ? 3.0 : _levels[i],
              decoration: BoxDecoration(
                color: empty ? CcColors.borderStrong : CcColors.success,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
