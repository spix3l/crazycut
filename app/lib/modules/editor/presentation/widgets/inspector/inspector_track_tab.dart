import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:crazycut_app/modules/project/domain/area_track.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/editor/application/editor_controller.dart';
import 'package:crazycut_app/modules/editor/infrastructure/tracking_service.dart';

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
    final regions = c.trackersFor(clip);
    final tracker = c.trackerForClip(clip);
    final pin = TrackPin.fromExtra(clip.extra);

    return ListenableBuilder(
      listenable: c.dependencies.tracking,
      builder: (context, _) {
        // The active region's id is known from the moment a solve is asked for,
        // before the tracker exists in the document — which is the run the user
        // is actually waiting on. The per-clip lookup stays as the fallback.
        final active = c.activeTrackerId;
        final job =
            (active == null
                ? null
                : c.dependencies.tracking.jobFor(active)) ??
            c.dependencies.tracking.jobForClip(clip.id);
        final running =
            job?.state == TrackingState.running ||
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
                    if (regions.isNotEmpty) ...[
                      for (final region in regions)
                        _RegionRow(
                          controller: c,
                          tracker: region,
                          selected: region.id == tracker?.id,
                        ),
                      const SizedBox(height: 8),
                    ],
                    CcButton(
                      label:
                          c.trackToolActive
                              ? 'Done drawing'
                              : regions.isEmpty
                              ? 'Draw region…'
                              : 'Draw another region…',
                      kind:
                          c.trackToolActive
                              ? CcButtonKind.secondary
                              : CcButtonKind.primary,
                      onPressed: () => c.trackToolActive = !c.trackToolActive,
                    ),
                    const SizedBox(height: 8),
                    _Note(
                      regions.isEmpty
                          ? 'Drag a box on the monitor over what the overlay '
                              'should follow, then it is tracked from there.'
                          : 'Drag a corner on the monitor to correct a region '
                              'and it re-tracks forward from that frame. Drag '
                              'on empty picture to track something else too.',
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
                        onPressed:
                            () => c.dependencies.tracking.cancel(
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
                      _Note(
                        'Puts a picture on ${c.trackerLabel(tracker)} and pins '
                        'it, on a track above this one, for exactly the '
                        'tracked range.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                  // Named, because these numbers describe one of possibly
                  // several regions on this clip.
                  child: CcSectionHeader(
                    c.trackerLabel(tracker).toUpperCase(),
                  ),
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
                    label: 'Delete ${c.trackerLabel(tracker).toLowerCase()}',
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
                child:
                    pin == null
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

    // Not "whatever appeared in doc.media": importing something already in the
    // project adds nothing (IMP-3 dedupes by hash), and reading it that way
    // made this work once and then silently do nothing.
    final asset = await c.importAndResolve(file.path);
    if (asset == null) {
      c.reportTrackProblem('That image could not be imported.');
      return;
    }

    final id = c.replaceRegionWithAsset(
      trackerId: trackerId,
      assetId: asset.id,
    );
    if (id == null) {
      c.reportTrackProblem('The tracked region could not take an image.');
      return;
    }
    // The region is solved and filled; leaving the draw tool armed would put
    // grab handles over the result the user is now looking at.
    c.trackToolActive = false;
  }

  static String _percent(double v) => '${(v * 100).round()}%';
}

/// One of the clip's tracked regions (**TRK-27**). Tapping it makes it the
/// active region, which is what the canvas handles, the readout below and
/// *Replace with image* all act on.
class _RegionRow extends StatelessWidget {
  const _RegionRow({
    required this.controller,
    required this.tracker,
    required this.selected,
  });

  final EditorController controller;
  final Tracker tracker;
  final bool selected;

  @override
  Widget build(BuildContext context) => CcTappable(
    onTap: () => controller.activeTrackerId = tracker.id,
    child: Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? CcColors.elevated : null,
        borderRadius: BorderRadius.circular(CcRadius.sm),
        border: Border.all(
          color: selected ? CcColors.accent : CcColors.border,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            controller.trackerLabel(tracker),
            style: CcType.style(
              size: 12,
              color: selected ? CcColors.textPrimary : CcColors.textSecondary,
            ),
          ),
          Text(
            '${tracker.sampleCount} samples',
            style: CcType.style(size: 11, color: CcColors.textTertiary),
          ),
        ],
      ),
    ),
  );
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
      builder:
          (anchor) => CcButton(
            label: 'Pin to tracked region…',
            onPressed:
                () => showCcMenu(anchor, [
                  for (final tracker in available)
                    CcMenuItem(
                      // Named per region, not per clip: one shot can carry
                      // several, and "Shot" three times says nothing.
                      '${controller.doc.clipById(tracker.sourceClipId)?.label ?? tracker.id}'
                      ' · ${controller.trackerLabel(tracker)}',
                      onTap:
                          () =>
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
          builder:
              (anchor) => CcButton(
                label: _labels[pin.mode]!,
                kind: CcButtonKind.secondary,
                onPressed:
                    () => showCcMenu(anchor, [
                      for (final entry in _labels.entries)
                        CcMenuItem(
                          entry.value,
                          checked: entry.key == pin.mode,
                          onTap:
                              () => controller.setPinMode(clip.id, entry.key),
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
    final shift = HardwareKeyboard.instance.isShiftPressed ? _coarse : _step;
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
              onPressed: () => controller.nudgePin(clip.id, Offset(-dx, -dy)),
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
        Text(
          label,
          style: CcType.style(size: 12, color: CcColors.textSecondary),
        ),
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
