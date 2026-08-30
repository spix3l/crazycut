import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
        // Keyed on the clip, not the tracker: a first solve has no tracker in
        // the document yet, so looking it up by tracker id showed nothing at
        // all for the run the user is actually waiting on.
        final job = TrackingService.instance.jobForClip(clip.id) ??
            (tracker == null
                ? null
                : TrackingService.instance.jobFor(tracker.id));
        final running = job?.state == TrackingState.running ||
            job?.state == TrackingState.queued;
        final rejection = c.trackRejection;

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
                    if (rejection != null) ...[
                      const SizedBox(height: 8),
                      _Note(rejection, tone: CcColors.warning),
                    ],
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
                        onPressed: () => TrackingService.instance.cancel(
                          job.request.trackerId,
                        ),
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
                  child: CcSectionHeader('REPLACE'),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CcButton(
                        label: 'Replace with image…',
                        onPressed: () => _replaceWithFile(tracker.id),
                      ),
                      const SizedBox(height: 6),
                      const _Note(
                        'Puts a picture on the region and pins it, on a track '
                        'above this one, for exactly the tracked range.',
                      ),
                    ],
                  ),
                ),
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

  /// Import a picture and drop it straight onto the region.
  ///
  /// This is the feature in one action. Doing it by hand means importing,
  /// finding a free track, dragging the clip to the tracked range, selecting
  /// it, and pinning it to a tracker named after a different clip — enough
  /// steps that nobody would guess the feature was there.
  Future<void> _replaceWithFile(String trackerId) async {
    const types = [
      XTypeGroup(
        label: 'Images',
        extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'tiff'],
      ),
    ];
    final file = await openFile(acceptedTypeGroups: types);
    if (file == null) return;

    // importPaths reports a count, not ids, so the new asset is whatever
    // appeared. Comparing before and after is exact, and avoids widening that
    // API for one caller.
    final before = {for (final m in c.doc.media) m.id};
    await c.importPaths([file.path]);
    final added = c.doc.media.where((m) => !before.contains(m.id)).toList();
    if (added.isEmpty) return;

    c.replaceRegionWithAsset(trackerId: trackerId, assetId: added.last.id);
    // The region is solved and filled; leaving the draw tool armed would put
    // grab handles over the result the user is now looking at.
    c.trackToolActive = false;
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
        const SizedBox(height: 12),
        const CcSectionHeader('NUDGE'),
        const SizedBox(height: 6),
        const _Note(
          'Offsets the overlay from the region it follows. The offset is kept '
          'on the pin, so a re-track does not undo it.',
        ),
        const SizedBox(height: 6),
        _NudgePad(controller: controller, clip: clip, pin: pin),
        const SizedBox(height: 12),
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

/// Arrow pad for [EditorController.nudgePin], plus a reset. One step is one
/// sequence pixel; holding Shift moves ten, matching the timeline's nudge.
class _NudgePad extends StatelessWidget {
  const _NudgePad({
    required this.controller,
    required this.clip,
    required this.pin,
  });

  final EditorController controller;
  final Clip clip;
  final TrackPin pin;

  static const double _step = 1;
  static const double _coarse = 10;

  void _nudge(double dx, double dy) {
    final shift =
        HardwareKeyboard.instance.isShiftPressed ? _coarse : _step;
    controller.nudgePin(clip.id, Offset(dx * shift, dy * shift));
  }

  @override
  Widget build(BuildContext context) {
    final offset = pin.offset;
    // Every corner carries the same nudge, so the first is the whole story.
    final dx = offset[0], dy = offset[1];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _NudgeButton(
              icon: LucideIcons.arrowUp,
              onPressed: () => _nudge(0, -1),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _NudgeButton(
              icon: LucideIcons.arrowLeft,
              onPressed: () => _nudge(-1, 0),
            ),
            const SizedBox(width: 4),
            _NudgeButton(
              icon: LucideIcons.rotateCcw,
              enabled: dx != 0 || dy != 0,
              onPressed: () => controller.nudgePin(
                clip.id,
                Offset(-dx, -dy),
              ),
            ),
            const SizedBox(width: 4),
            _NudgeButton(
              icon: LucideIcons.arrowRight,
              onPressed: () => _nudge(1, 0),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _NudgeButton(
              icon: LucideIcons.arrowDown,
              onPressed: () => _nudge(0, 1),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            dx == 0 && dy == 0
                ? 'On the region'
                : '${dx.round()}, ${dy.round()} px',
            style: CcType.style(size: 11, color: CcColors.textTertiary),
          ),
        ),
      ],
    );
  }
}

class _NudgeButton extends StatelessWidget {
  const _NudgeButton({
    required this.icon,
    required this.onPressed,
    this.enabled = true,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) => CcTappable(
    onTap: enabled ? onPressed : null,
    child: Container(
      width: 30,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: BorderRadius.circular(CcRadius.sm),
        border: Border.all(color: CcColors.border),
      ),
      child: CcIcon(
        icon,
        size: 13,
        color: enabled ? CcColors.textSecondary : CcColors.textTertiary,
      ),
    ),
  );
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
