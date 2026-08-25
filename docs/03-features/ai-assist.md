# Feature Spec — AI Assist

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-25
> Requirements prefix: **AI** · Model: `02-data-model.md` §5 · Architecture: `01-architecture.md` §2/§8/§15
> First consumer: `03-features/shorts.md` (**SHT**)

## Summary

A small, vendor-neutral layer that lets CrazyCut ask a language model questions about a
project and — eventually — let it make edits. Two halves:

1. **Speech-to-text**, entirely local (whisper-class model in the engine). Produces a
   timed transcript for any media with audio.
2. **An LLM provider abstraction** — one interface, several interchangeable adapters, one
   of which is a fully local model server. Plus an agent loop and a bridge that turns tool
   calls into ordinary undoable document edits.

The layer is built to outlive its first feature. Shorts (**SHT**) is the first consumer and
uses only the read path; the write path exists so the next feature does not start from zero.

**No vendor is privileged.** The core speaks a normalized message/tool/schema model and
knows nothing about any particular API. Swapping, adding, or self-hosting a model must never
require touching the core, the agent loop, the tool bridge, or any feature above them.

## User stories

- As Dev, I point CrazyCut at a local model I already run and never send anything to a cloud.
- As Maya, I paste an API key for the service I already pay for, and CrazyCut uses it.
- As Sam, I never see an AI button at all, because I never configured a provider.

## Non-goals (v1)

- No CrazyCut account, no CrazyCut-hosted inference, no bundled API key — ever.
- No media (video, audio, frames) leaves the machine. Transcript **text** and project
  metadata only, and only to the endpoint the user configured.
- No autonomous editing. Every model-proposed change is reviewed by the user before it
  is applied.
- No fine-tuning, no embeddings/vector store, no RAG over the media library.

## Functional requirements

### Configuration
- **AI-1** AI is **off until configured**. With no provider configured, every AI entry point
  is hidden, no network call is ever attempted, and the app behaves exactly as it does today.
- **AI-2** Settings → AI selects a provider adapter, a base URL, a model name and (where the
  provider needs one) an API key. Connection can be tested from the dialog without running a
  real task.
- **AI-3** Secrets are stored in the OS keychain via the `dev.crazycut/system` platform
  channel. They are never written to a `.crazycut` file, to preferences, to a log, or to the
  diagnostics bundle (**PRJ-15**), and are never echoed back into the settings field once saved.
- **AI-4** The settings screen states plainly which endpoint will be contacted, what is sent
  (transcript text and project metadata; never media), and that result quality depends on the
  model chosen.

### Provider abstraction
- **AI-5** All features talk to `LlmProvider`, never to an adapter. The interface carries:
  `complete(request)`, `stream(request)`, `capabilities`, and an `id`.
- **AI-6** Requests and responses use normalized types — messages of text / tool-call /
  tool-result parts, tool definitions with JSON Schema, an optional response schema, and a
  `reasoning` **intent** (`none` | `auto` | `deep`). Reasoning is an intent rather than a
  token count because providers express thinking depth in mutually incompatible ways; each
  adapter maps the intent onto its own wire format.
- **AI-7** Every adapter maps its transport and status codes onto one error taxonomy:
  auth, rate-limit (carrying retry-after when known), context-overflow, content-filtered,
  transport, provider. Callers never branch on a vendor's status codes. Retry policy is
  implemented once, in the core, and mirrors the export worker's single automatic retry
  (**EXP-11**).
- **AI-8** Adapters declare capabilities: native tool calling, server-enforced JSON schema,
  streaming, and context window. Capabilities are probed once per configuration and cached.
- **AI-9** **Capability degradation is the core's job, not the caller's.** Where a provider
  lacks server-enforced schema output, the core injects the schema into the prompt, extracts
  the first balanced JSON value from the reply, validates it, and retries once with the
  validation error fed back. Where a provider lacks native tool calling, a text tool protocol
  is used over the same path. Callers write against the capable path and get identical
  results either way.
- **AI-10** Shipped adapters: an OpenAI-compatible chat-completions adapter with a
  configurable base URL (covering the majority of hosted and self-hosted stacks), an
  Anthropic Messages adapter, and a local Ollama adapter. Adding an adapter is one new file
  plus a registry entry; no existing file changes shape.

### Agent loop
- **AI-11** `AgentRunner` drives the tool loop: send, and while the model asks for tools,
  execute every requested call and return **all** results in a single following turn.
  Splitting results across turns is not allowed — it teaches models to stop making parallel
  calls.
- **AI-12** A failed tool returns an error result to the model rather than being dropped, so
  the model can recover. A tool that throws never propagates out of the loop.
- **AI-13** The loop has a hard iteration cap and cooperative cancellation checked between
  turns, matching the export worker's cancellation contract (`01-architecture.md` §8).
- **AI-14** Every request/response pair is recorded to an in-memory session log with token
  usage, viewable from the AI settings screen, so cost and behaviour are inspectable.

### Document tools
- **AI-15** Tools that mutate the project go through `EditTransaction`, so **one tool call is
  one undo step** and inherits autosave, backups and invariant validation (**TIM-20**,
  **PRJ-6–9**) with no special-casing.
- **AI-16** A model-proposed geometry value is never trusted: ranges are clamped to the media
  and the sequence, and invalid entities are refused by the same validation path as a
  hand-made edit (`02-data-model.md` §10).
- **AI-17** v1 ships read-only `list_clips` and `get_sequence_info` plus one mutating
  `set_clip_range`, proved end-to-end. The set is deliberately small; it exists to keep the
  loop honest, not to expose the editor.

### Transcription
- **AI-18** Transcription runs **entirely locally** — a whisper-class model in the engine.
  It requires no provider configuration and no network at run time.
- **AI-19** The speech model is **not bundled**. On first use, CrazyCut asks to download it,
  showing the size up front, and writes it atomically (temp + rename) to the cache directory.
  Declining leaves transcription unavailable with a clear message; it never crashes and never
  downloads silently.
- **AI-20** Transcription runs in the export worker process as a `transcribe` job, reporting
  progress over the existing JSON-lines protocol, with the same ETA presentation and cancel
  affordance as an export (**EXP-8**).
- **AI-21** Transcripts are cached by media content hash beside thumbnails, peaks and proxies
  (`02-data-model.md` §7). Re-importing the same file never re-transcribes it.
- **AI-22** A transcript is timed segments (`start`, `end`, `text`) in the media's own time
  domain, so segment boundaries are directly usable as cut points.

## UX notes

- One **Settings → AI** screen owns configuration. Until it is filled in, no AI affordance
  appears anywhere else in the app.
- Long operations (transcription, a model call) use the export queue's visual language:
  progress, ETA, cancel. Nothing modal, nothing blocking — editing continues throughout.
- Before a request that costs money, show the token estimate; where the provider publishes
  rates, show the estimated cost too.
- Errors are stated in the user's terms: "your key was rejected", "the model is rate limited,
  retrying in 20 s", "this transcript is too long for the configured model's context window".

## Edge cases

- Provider reachable but model name wrong → surfaced as a provider error naming the model,
  not a generic failure.
- Local model server not running → transport error with a hint to start it, not a stack trace.
- Model returns prose around the JSON → handled by **AI-9**; only a second failure is an error.
- Model returns valid JSON that violates the schema → one repair round-trip, then an error.
- Transcript exceeds the model's context window → refuse before sending, with the measured
  size and the window in the message; suggest a smaller range or a larger-context model.
- Key deleted from the keychain out from under the app → treated as unconfigured (**AI-1**).
- Cancellation mid-request → the HTTP request is aborted, nothing is applied, no partial
  document edit is left behind.

## Acceptance criteria

1. With no provider configured, no AI UI is present and no outbound request is made during a
   full import → edit → export session.
2. The same feature code, run against all three shipped adapters, produces the same normalized
   response type and the same error type for the same conditions.
3. A provider declaring `jsonSchema: false` still returns a valid parsed object for a
   schema-shaped request, including when the reply wraps the JSON in prose.
4. A tool call that edits the document is undone by a single ⌘Z, and the resulting project
   passes loader validation.
5. Transcribing a 10-minute clip reports monotonic progress with an ETA, can be cancelled
   mid-run leaving no partial cache entry, and on a second run completes instantly from cache.
6. An API key entered in settings does not appear in the project file, the autosave, the log
   sidecar, or the diagnostics bundle.

## Changelog

- v0.1 — Initial draft. Leaves the `05-roadmap.md` §4 backlog ("auto-captions, local
  whisper-class model") alongside its first consumer, **SHT**.
