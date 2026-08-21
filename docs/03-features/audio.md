# Feature Spec — Audio

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-21
> Requirements prefix: **AUD** · Clock/mixing internals: `01-architecture.md` §2, §6

## Summary

Creators need audio that just works: visible waveforms, quick fades, music under voice, and exports at platform loudness. v1 delivers per-clip control, a simple mixer, detach/link, and loudness-normalized export — no multi-bus routing, no plugins.

## User stories

- As Maya, I duck music under my voice with two fades instead of learning sidechain compression.
- As Dev, I detach audio from my b-roll so it keeps playing while the video cuts away.
- As Sam, my export hits −14 LUFS without opening another app.

## Functional requirements

### Per-clip
- **AUD-1** Volume: linear gain slider −∞/−48…+12 dB (UI in dB; storage linear per `02-data-model.md`), scrub-drag on clip's volume line (horizontal rubber band across clip) for volume automation? — **v1: single static gain + fades only**; the rubber band is drawn from fade state, not freeform.
- **AUD-2** Fades: independent in/out with duration drag handles on clip corners (audio clips show curve overlay); curves: linear, exponential (default out), S-curve.
- **AUD-3** Mute per clip; pan/balance −1…+1 (stereo; mono files pan as expected).
- **AUD-4** Speed change: audio retimes; "preserve pitch" checkbox (default on) uses quality time-stretch; off = varispeed (pitch shifts). Stretch quality is best-effort v1 (documented); extreme stretch (>2×) may degrade gracefully.
- **AUD-5** Normalize clip action: peak-scan → apply gain to −1 dBFS peak (stores computed gain statically).

### Structure
- **AUD-6** Detach audio: splits A/V into linked clips (`linkedGroup`) on a free audio track at same sequence position; relink merges back when positions/speeds match.
- **AUD-7** Audio-only assets (music/VO) import like any media (IMP spec) and drop onto audio tracks; dropping onto video area auto-targets nearest audio track.
- **AUD-8** Audio never overlaps on one track (TIM-4): overlapping drops trim the earlier clip's tail (with toast + undo). Cross-track layering is the intended way to overlap sounds.
- **AUD-9** Transitions between adjacent audio-bearing clips create constant-power crossfades automatically (TRA-8).

### Mixer
- **AUD-10** Mixer panel: one strip per audio track + master: fader (−∞…+6 dB), mute, solo, stereo meter with peak-hold, pan knob. Track fader × clip gains compose multiplicatively.
- **AUD-11** Master limiter (safety brickwall, −1 dBFS ceiling) always on during preview/export to catch accidental clipping; toggleable.
- **AUD-12** Loudness tools: "Analyze sequence loudness" reports integrated LUFS; export option normalizes to target (default −14 LUFS via two-pass loudnorm, EXP spec).

### Monitoring & display
- **AUD-13** Waveforms render on all audio-bearing clips from cached peaks (IMP-7); refresh after speed/fade changes is visual-only (peaks unchanged by gain/fades).
- **AUD-14** Output device selectable in Settings; sample rate locked 48 kHz v1; device hot-swap (plug headphones) switches within 200 ms without stopping playback.
- **AUD-15** Scrubbing emits short muted-gain audio ticks; full-speed shuttle >2× may mute (documented, `01-architecture.md` §6).

## UX notes

- Clip corners double as fade handles when hovering audio region (video clips' linked audio too); cursor differentiates trim vs fade zones.
- Metering always visible in transport bar (master), even with mixer closed.
- Music workflow: dropping an audio file while a video clip is selected offers "Fit to clip" (speed-matches music duration ±10% then trims) — one-click, undoable.

## Edge cases

- Corrupt/truncated audio stream: clip plays silent with warning badge; probe data retained.
- 5.1/7.1 sources: downmixed to stereo at decode (documented); layout shown in asset properties.
- Drifting long VO vs video: sample-count clock prevents drift (`01-architecture.md` §6); resync events logged not surfaced.
- Detach on clip already detached: no-op with toast.

## Acceptance criteria

1. Fade-out drag on clip corner updates preview audibly in realtime; export waveform matches fade curve (golden audio test, RMS sampling).
2. Detach → move video only → linked badge shows "out of sync" indicator with click-to-sync.
3. Sequence analyze reports LUFS within ±0.5 of reference ffmpeg measurement on test corpus.
4. Hot-unplug output device mid-playback: playback continues on default device ≤ 200 ms gap, no crash.

## Out of scope (v1)

Freeform volume automation lanes [v1.5], effects (EQ/compression/reverb) [v1.5 candidates], sidechain ducking (presets emulate via fades), surround delivery, audio recording (VO capture) [v1.5], score/soundtrack library.

## Changelog

- v0.1 — Initial draft.
