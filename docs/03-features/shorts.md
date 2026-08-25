# Feature Spec — Shorts

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-25
> Requirements prefix: **SHT** · Depends on: `03-features/ai-assist.md` (**AI**)
> Model: `02-data-model.md` §5 · Projects: `03-features/projects.md` (**PRJ**)

## Summary

Turn a long recording into a set of vertical shorts. CrazyCut transcribes the clip locally,
asks the configured model to nominate the moments that stand on their own, and shows them as
reviewable candidates. Accepting one spawns a new 9:16 project containing just that moment,
ready to polish and export.

The driving case: Dev drops in a 40-minute stream VOD and leaves with four 9:16 projects,
without having scrubbed the timeline once.

## User stories

- As Dev, I import a long VOD, get a ranked list of candidate moments with titles, keep four
  and bin the rest.
- As Dev, a candidate starts two seconds late, so I nudge its in-point before accepting it.
- As Maya, I want each accepted short as its own project so I can add captions and a hook
  without touching my main edit.

## Non-goals (v1)

- No subject tracking or auto-reframe. Framing is centre-crop; the user drags it if they want
  something else. Face/saliency-driven reframing is its own feature.
- No caption burn-in. (`00-product-overview.md` §5 keeps subtitle tooling out of v1.)
- No batch export. Accepted shorts become projects; exporting them uses the normal queue.
- No downloading from YouTube or any other platform. The user imports the file.

## Functional requirements

### Entry
- **SHT-1** "Find shorts…" appears in the editor toolbar only when a provider is configured
  (**AI-1**) and the sequence contains at least one clip with audio.
- **SHT-2** Running it transcribes the source if no cached transcript exists (**AI-18–21**),
  showing transcription progress first and proposal progress second, as one operation with
  one cancel.

### Proposal
- **SHT-3** The transcript is sent as a single request through `LlmProvider` asking for a
  ranked list of candidates. It is not an agent loop: a full transcript fits comfortably in a
  modern context window, so there is nothing to retrieve and a single call is cheaper and more
  predictable.
- **SHT-4** Each candidate carries `startSec`, `endSec`, `title`, `hook`, `reason` and
  `confidence`. The response is requested against a JSON schema; on providers without schema
  support the core's fallback applies (**AI-9**) and the calling code is unchanged.
- **SHT-5** Candidate boundaries are asked to fall on transcript segment boundaries, so cuts
  land between words rather than through them.
- **SHT-6** **Model output is never trusted for geometry.** After parsing, CrazyCut clamps
  every candidate to the media bounds, drops any shorter than 5 s or longer than 180 s,
  resolves overlaps in favour of the higher-confidence candidate, and caps the list at 12.
  A response that yields zero valid candidates is reported as "no moments found", not an error.
- **SHT-7** Proposal is cancellable at any point and leaves no project, marker, or cache entry
  behind.

### Review
- **SHT-8** Candidates appear in a Shorts panel using the export queue's card metaphor: title,
  hook, duration, a thumbnail from the candidate's midpoint, and the transcript excerpt it was
  drawn from.
- **SHT-9** Per-candidate actions: preview (sets in/out and plays the range), nudge in/out by
  a frame or a segment, accept, reject. Nudging is clamped by **SHT-6**'s rules.
- **SHT-10** Candidates are also written to the timeline as markers so they are visible in
  context. Rejecting a candidate removes its marker. Marker creation for one proposal run is
  a single undo step.
- **SHT-11** Nothing is created until the user accepts. Rejecting every candidate leaves the
  project byte-identical to before the run.

### Output
- **SHT-12** Accepting a candidate creates a **new project** — `1080×1920`, source fps, source
  audio rate — containing one video clip and its linked audio clip covering the candidate's
  range, and nothing else.
- **SHT-13** The source `MediaAsset` is carried across with its existing `id` and `hash`, so
  the new project reuses the cached thumbnails, peaks, proxy and transcript immediately and
  never re-probes or re-transcribes.
- **SHT-14** The clip is created with `framing: "fill"`, which the compositor already defines
  as crop-to-fill, so a 16:9 source fills the 9:16 canvas centred with no new render code and
  the canvas gizmo can reposition the crop straight away.
- **SHT-15** The new project is written atomically beside the source project as
  `<project> — <title>.crazycut`, de-duplicated with a numeric suffix on collision, exactly
  like an export output path (**EXP-13**). Accepting several candidates writes several
  projects; the editor stays on the original.
- **SHT-16** A title that is empty or not filename-safe falls back to the timecode of the
  candidate's in-point. Titles never determine anything but the filename and the card label.

## UX notes

- The panel docks where the export queue docks and shares its card, progress and status-line
  vocabulary — this is the same kind of object (a queue of proposed work), and should not
  invent a second visual language.
- Ordering is by model confidence, but confidence is shown as a coarse badge rather than a
  number: it is a hint, not a measurement.
- The empty state is honest about why: no provider configured, no audio in the sequence, no
  moments found, or the model declined.
- Accepting shows a toast naming the created project with a reveal action; it does not
  navigate away mid-review.

## Edge cases

- Sequence has no audio, or transcription yields no speech → "no speech found", no request is
  sent and no cost is incurred.
- Source is already vertical → the new project is still 1080×1920 and `fill` is a no-op crop;
  nothing is upscaled beyond the source.
- Candidate range extends past the media end (model hallucinated a timestamp) → clamped by
  **SHT-6**; if clamping leaves it under 5 s it is dropped.
- Source media goes offline between proposal and acceptance → the new project is created with
  the asset marked offline, and the standard relink flow (**IMP-15**) repairs it. Acceptance is
  never blocked on media presence.
- The source project is unsaved → prompt to save first, since **SHT-15** writes beside it.
- Two candidates produce the same title → suffixed per **SHT-15**.
- Model returns 40 candidates → capped at 12 by **SHT-6**, highest confidence kept.

## Performance

- Proposal adds one model round-trip; transcription dominates wall-clock time and is bounded
  by **AI-20**'s progress/ETA contract.
- **Export note:** a `framing: "fill"` clip is a non-identity transform, so it is disqualified
  from the export passthrough fast path and renders through the full composite pipeline. This
  is correct, but a short exports slower than an equivalent untouched trim; it is called out
  here so the difference is not mistaken for a regression.

## Acceptance criteria

1. Import a 10-minute clip with speech → run Find shorts → candidates appear with titles,
   durations and thumbnails, all within the media bounds and none overlapping.
2. Accept two candidates → two `.crazycut` files exist beside the source project, each
   `1080×1920`, each with exactly one video clip and one linked audio clip at the right range.
3. Open an accepted short and export it with the Shorts preset → output is 1080×1920 and
   centre-cropped, and its content matches the reviewed range frame-for-frame.
4. Reject every candidate → the source project is unchanged and no files are written.
5. Cancel mid-proposal → no markers, no projects, no partial transcript cache entry.
6. Run against a provider without server-side JSON schema support → identical candidate list
   shape, no code path difference visible to the feature.

## Changelog

- v0.1 — Initial draft.
