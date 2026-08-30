import 'package:flutter/widgets.dart' hide Clip;

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/area_track.dart';
import '../../../../../data/project.dart';
import '../../../../../state/editor_controller.dart';
import '../../../../../state/tracking_service.dart';

/// Area tracking for the selected clip (**TRK**).
///
/// Three jobs: arm the canvas region tool, report what the solve produced —
/// including where it stopped being trustworthy — and manage the pin that makes
/// an overlay follow it.
class TrackTab extends StatelessWidget {
  const TrackTab({super.key, required this.controller, required this.clip});

  final EditorController controller;
  final Clip clip;

  EditorController get c => controller;

  @override
  Widget build(BuildContext context) {
    final tracker = c.trackerForClip(clip);
    final pin = TrackPin.fromExtra(clip.extra);

    return ListenableBuilder(
      listenable: TrackingService.instance,
      builder: (context, _) {
        final job = tracker == null
            ? null
            : TrackingService.instance.jobFor(tracker.id);
        final running = job?.state == TrackingState.running ||
            job?.state == TrackingState.queued;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: CcSectionHeader('REGION'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CcButton(
                      label: c.trackToolActive
                          ? 'Done drawing'
                          : tracker == null
                          ? 'Draw region…'
                          : 'Adjust region…',
                      kind: c.trackToolActive
                          ? CcButtonKind.secondary
                          : CcButtonKind.primary,
                      onPressed: () =>
                          c.trackToolActive = !c.trackToolActive,
                    ),
                    const SizedBox(height: 8),
                    _Note(
                      tracker == null
                          ? 'Drag a box on the monitor over what the overlay '
                                'should follow, then it is tracked from there.'
                          : 'Drag a corner on the monitor to correct the '
                                'region, and it re-tracks forward from that '
                                'frame.',
                    ),
                  ],
                ),
              ),

              if (running) ...[
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Note(job!.statusLine),
                      const SizedBox(height: 8),
                      CcButton(
                        label: 'Cancel',
                        kind: CcButtonKind.secondary,
                        onPressed: () =>
                            TrackingService.instance.cancel(tracker!.id),
                      ),
                    ],
                  ),
                ),
              ] else if (job?.state == TrackingState.failed) ...[
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: _Note(job!.statusLine, tone: CcColors.error),
                ),
              ],

              if (tracker != null && !running) ...[
                const SizedBox(height: 14),
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 0, 14, 8),
                  child: CcSectionHeader('SOLVE'),
                ),
                _Stat('Samples', '${tracker.sampleCount}'),
                _Stat(
                  'Confidence here',
                  _percent(tracker.confidenceAt(c.clipLocalTime(clip))),
                ),
                _Stat('Weak spans', '${tracker.lowConfidenceSpans().length}'),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: CcButton(
                    label: 'Delete tracker',
                    kind: CcButtonKind.secondary,
                    onPressed: () => c.deleteTracker(tracker.id),
                  ),
                ),
              ],

              const SizedBox(height: 14),
              const Padding(
                padding: EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: CcSectionHeader('PIN'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: pin == null
                    ? _PinPicker(controller: c, clip: clip)
                    : _PinControls(controller: c, clip: clip, pin: pin),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _percent(double v) => '${(v * 100).round()}%';
}

/// Offers the trackers this clip could follow. A clip cannot follow its own
/// region — that would pin it to itself.
class _PinPicker extends StatelessWidget {
  const _PinPicker({required this.controller, required this.clip});

  final EditorController controller;
  final Clip clip;

  @override
  Widget build(BuildContext context) {
    final available = [
      for (final tracker in controller.doc.trackers)
        if (tracker.sourceClipId != clip.id) tracker,
    ];
    if (available.isEmpty) {
      return const _Note(
        'Track a region on another clip, then pin this one to it so it '
        'follows.',
      );
    }
    return Builder(
      builder: (anchor) => CcButton(
        label: 'Pin to tracked region…',
        onPressed: () => showCcMenu(anchor, [
          for (final tracker in available)
            CcMenuItem(
              controller.doc.clipById(tracker.sourceClipId)?.label ??
                  tracker.id,
              onTap: () =>
                  controller.pinClipToTracker(clip.id, tracker.id),
            ),
        ]),
      ),
    );
  }
}

class _PinControls extends StatelessWidget {
  const _PinControls({
    required this.controller,
    required this.clip,
    required this.pin,
  });

  final EditorController controller;
  final Clip clip;
  final TrackPin pin;

  static const Map<PinMode, String> _labels = {
    PinMode.position: 'Position only',
    PinMode.positionScale: 'Position + scale',
    PinMode.positionScaleRotation: 'Position + scale + rotation',
    PinMode.cornerPin: 'Corner pin (perspective)',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Builder(
          builder: (anchor) => CcButton(
            label: _labels[pin.mode]!,
            kind: CcButtonKind.secondary,
            onPressed: () => showCcMenu(anchor, [
              for (final entry in _labels.entries)
                CcMenuItem(
                  entry.value,
                  checked: entry.key == pin.mode,
                  onTap: () => controller.setPinMode(clip.id, entry.key),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        const _Note(
          'Simpler modes keep this clip’s own shape and borrow only part '
          'of the solve, which is what makes a jittery track usable.',
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: CcButton(
                label: 'Bake',
                kind: CcButtonKind.secondary,
                onPressed: () => controller.bakePinToKeyframes(clip.id),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: CcButton(
                label: 'Unpin',
                kind: CcButtonKind.secondary,
                onPressed: () => controller.unpinClip(clip.id),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const _Note(
          'Baking turns the tracked motion into ordinary keyframes and removes '
          'the pin, so it can be hand-edited from here on.',
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: CcType.style(size: 12, color: CcColors.textSecondary)),
        Text(value, style: CcType.style(size: 12)),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.tone});

  final String text;
  final Color? tone;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: CcType.style(size: 11, color: tone ?? CcColors.textTertiary),
  );
}
