# Feature Spec — Captions

> Status: Draft v0.1 · Last updated: 2026-08-26
> Requirements prefix: **CAP**

## Summary

CrazyCut turns local transcripts or subtitle files into editable, styled
caption tracks. Caption timing remains independent from ordinary text clips so
creators can correct a whole video quickly and export either burned-in text or
standards-compatible sidecars.

## Requirements

### Model and editing

- **CAP-1** A project stores typed caption tracks with language, shared style,
  cues, and optional word timing. Cue and word times use exact sequence time.
- **CAP-2** Loading repairs negative, overlapping, shorter-than-one-frame, and
  invalid word spans deterministically and reports every repair.
- **CAP-3** Text, speaker, timing, split, merge, nudge, style, create, and delete
  actions are undoable; one committed gesture is one command.
- **CAP-4** Timeline and list selections share one selected cue and playhead.
  The timeline provides direct move/trim handles; the list supports efficient
  keyboard correction.
- **CAP-5** Changing cue text clears stale recognized-word correspondence.

### Generation and interchange

- **CAP-6** A cached local transcript converts to captions without a provider or
  network request. Segmentation considers silence, punctuation, cue length,
  duration, and reading speed.
- **CAP-7** When only segment timing exists, estimated word timing is retained
  for highlighted-word styles and may later be replaced by recognizer timing.
- **CAP-7a** **Auto captions** transcribes the selected timeline clip locally,
  or the longest available clip with audio when none is selected. Source trims
  and clip speed are mapped into sequence time. The generated track is one
  undoable edit and transcription can be cancelled from the timeline toolbar.
- **CAP-8** SRT and WebVTT import accepts BOM/CRLF, multiline cues, and WebVTT
  metadata/settings; malformed cues are isolated and reported.
- **CAP-9** SRT and WebVTT export is deterministic and uses final sequence time.

### Rendering and export

- **CAP-10** Active cues render after video layers through the shared native
  preview/export compositor.
- **CAP-11** Caption style owns font, size, colors, alignment, normalized safe
  position, maximum width, and optional active-word highlighting.
- **CAP-12** Layout is cached and supports Unicode, multiline text, font
  fallback, horizontal projects, and vertical projects.
- **CAP-13** Export offers independent burned-in, SRT sidecar, and WebVTT
  sidecar controls. Disabling burn-in preserves the compositor fast path.

## Acceptance criteria

1. Convert a ten-minute cached transcript, correct text/timing in the list and
   lane, undo the changes, reopen the project, and recover the same result.
2. Import representative SRT and WebVTT files and export them within one frame
   of their repaired sequence timing.
3. Preview and exported pixels match at cue start, active-word boundary, cue
   end, and overlapping video transition frames.
4. Burned-in caption export remains within the representative performance
   budget and a sidecar-only export does not force caption compositing.
5. A malformed cue or word is quarantined without losing valid siblings.
6. Delete a caption track from its timeline header menu and undo to restore
   every cue and style setting.

## Out of scope for the first caption release

CEA-608/708 and broadcast subtitle formats, live transcription, collaborative
review, automatic speaker recognition, and automatic translation. These require
separate specs.

Motion-tracked captions also stay out. Area tracking now has its spec
(`03-features/tracking.md`, **TRK**), but it pins clips, and captions are cues on a caption
track rather than clips — attaching one to a tracker is its own change.
