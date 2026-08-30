#include "render/renderer.h"

#include <algorithm>
#include <cmath>
#include <cstring>

extern "C" {
#include <libavformat/avformat.h>
}

#include "core/log.h"
#include "media/frame.h"
#include "model/project.h"

namespace cc {
namespace {

using json = nlohmann::json;

double clampd(double v, double lo, double hi) { return std::min(std::max(v, lo), hi); }

RgbaSurface offlineSlate(int w, int h) {
  RgbaSurface out{w, h, std::vector<uint8_t>(static_cast<size_t>(w) * h * 4)};
  for (int y = 0; y < h; ++y) {
    for (int x = 0; x < w; ++x) {
      uint8_t* q = out.rgba.data() + (static_cast<size_t>(y) * w + x) * 4;
      const bool dark = ((x / 24) + (y / 24)) % 2 == 0;
      const uint8_t v = dark ? 40 : 64;
      q[0] = v; q[1] = v; q[2] = v; q[3] = 255;
    }
  }
  return out;
}

// A fully transparent 1x1 surface. Used where a layer has legitimately
// nothing to draw this frame (e.g. a typewriter reveal before its first
// character), so compositing it is a no-op instead of the offline slate.
RgbaSurface transparentSurface() {
  return RgbaSurface{1, 1, std::vector<uint8_t>(4, 0)};
}

std::string captionTextureKey(const json& track, const json& item,
                              const RationalTime& time) {
  std::string key = "caption:" + track.value("id", "") + ":" +
                    item.value("id", "");
  const json& style = track.contains("style") && track["style"].is_object()
                          ? track["style"]
                          : json::object();
  if (!style.value("highlightWords", false) || !item.contains("words") ||
      !item["words"].is_array()) {
    return key;
  }
  int index = 0;
  for (const json& word : item["words"]) {
    if (word.is_object() && word.contains("start") && word.contains("end")) {
      const auto start = parseJsonTime(word["start"]);
      const auto end = parseJsonTime(word["end"]);
      if (start && end && time >= *start && time < *end) {
        return key + ":h:" + std::to_string(index);
      }
    }
    ++index;
  }
  return key;
}

// Loads a still image or decodes a video frame at [sourceSeconds].
Error loadMediaFrame(const std::string& path, double sourceSeconds,
                     const RenderContext& ctx, RgbaSurface* out) {
  // Images decode through the same ffmpeg path; extractFrameRgba handles both.
  // The frame buffer is reused across calls: extractFrameRgba resizes it, so
  // a steady stream of same-sized frames never reallocates.
  thread_local DecodedFrame frame;
  Error err = extractFrameRgba(path, sourceSeconds, ctx.sequenceWidth, &frame);
  if (err != Error::None) return err;
  out->width = frame.width;
  out->height = frame.height;
  // Hand the decoded allocation to the compositor instead of copying a full
  // RGBA frame. The decoder receives the compositor's previous scratch buffer
  // and reuses that allocation on the next call.
  out->rgba.swap(frame.rgba);
  return Error::None;
}

// EXP-15: exposure corrections are linear-light gains, same math as the
// exposure effect (FX-5). A 256-entry LUT gives bit-identical results to a
// float round-trip for opaque video pixels at a fraction of the cost.
float srgbToLinear(float c) {
  return c <= 0.04045f ? c / 12.92f : std::pow((c + 0.055f) / 1.055f, 2.4f);
}

float linearToSrgb(float c) {
  c = clampd(c, 0.0f, 1.0f);
  return c <= 0.0031308f ? c * 12.92f : 1.055f * std::pow(c, 1.f / 2.4f) - 0.055f;
}

void applyExposureGain(RgbaSurface* surf, double stops) {
  const float m = static_cast<float>(std::pow(2.0, stops));
  uint8_t lut[256];
  for (int v = 0; v < 256; ++v) {
    lut[v] = static_cast<uint8_t>(std::lround(
        linearToSrgb(srgbToLinear(v / 255.f) * m) * 255.f));
  }
  for (size_t i = 0; i + 3 < surf->rgba.size(); i += 4) {
    surf->rgba[i] = lut[surf->rgba[i]];
    surf->rgba[i + 1] = lut[surf->rgba[i + 1]];
    surf->rgba[i + 2] = lut[surf->rgba[i + 2]];
  }
}

// Mean linear-light Rec.709 luma of one decoded frame.
double frameLuma(const DecodedFrame& frame) {
  const size_t n = static_cast<size_t>(frame.width) * frame.height;
  if (n == 0 || frame.rgba.size() < n * 4) return -1.0;
  double sum = 0.0;
  for (size_t i = 0; i < n; ++i) {
    sum += 0.2126 * srgbToLinear(frame.rgba[i * 4] / 255.0) +
           0.7152 * srgbToLinear(frame.rgba[i * 4 + 1] / 255.0) +
           0.0722 * srgbToLinear(frame.rgba[i * 4 + 2] / 255.0);
  }
  return sum / static_cast<double>(n);
}

}  // namespace

RenderIndex::RenderIndex(const json& document) : document_(&document) {
  if (document.contains("tracks") && document["tracks"].is_array()) {
    for (const json& t : document["tracks"]) {
      if (!t.is_object() || t.value("kind", "") != "video") continue;
      videoTracks_.push_back(
          Track{t.value("id", ""), t.value("index", 0), t.value("hidden", false), {}});
    }
  }
  std::stable_sort(videoTracks_.begin(), videoTracks_.end(),
                   [](const Track& a, const Track& b) { return a.index < b.index; });

  if (document.contains("clips") && document["clips"].is_array()) {
    for (const json& c : document["clips"]) {
      if (!c.is_object()) continue;
      const std::string id = c.value("id", "");
      if (!id.empty()) clipsById_[id] = &c;
      const std::string trackId = c.value("trackId", "");
      auto track = std::find_if(
          videoTracks_.begin(), videoTracks_.end(),
          [&](const Track& t) { return t.id == trackId; });
      if (track == videoTracks_.end()) continue;  // audio track, or unknown
      // Times are parsed once here; skipping a clip whose times do not parse
      // is what the per-frame scan did, so it stays out of the index entirely.
      const auto start = parseJsonTime(c.at("start"));
      const auto duration = parseJsonTime(c.at("duration"));
      if (!start || !duration) continue;
      track->clips.push_back(ClipSpan{&c, *start, *start + *duration});
    }
  }

  if (document.contains("transitions") && document["transitions"].is_array()) {
    for (const json& t : document["transitions"]) {
      if (!t.is_object()) continue;
      transitionsAsA_[t.value("aClipId", "")] = &t;
      transitionsAsB_[t.value("bClipId", "")] = &t;
    }
  }
}

const json* RenderIndex::clipAt(const Track& track,
                                const RationalTime& time) const {
  const json* best = nullptr;
  for (const ClipSpan& span : track.clips) {
    if (time >= span.start && time < span.end) best = span.clip;
  }
  return best;
}

const json* RenderIndex::clipById(const std::string& id) const {
  const auto it = clipsById_.find(id);
  return it == clipsById_.end() ? nullptr : it->second;
}

const json* RenderIndex::transitionAsA(const std::string& clipId) const {
  const auto it = transitionsAsA_.find(clipId);
  return it == transitionsAsA_.end() ? nullptr : it->second;
}

const json* RenderIndex::transitionAsB(const std::string& clipId) const {
  const auto it = transitionsAsB_.find(clipId);
  return it == transitionsAsB_.end() ? nullptr : it->second;
}

namespace {

// Does this clip carry a transform that is anything other than a fixed
// identity? Keyframed parameters are refused outright: they are identity only
// at some instants, and the whole point of the per-clip decision is that the
// answer cannot change part way through.
bool hasNonIdentityTransform(const json& clip, int width, int height) {
  if (!clip.contains("transform") || !clip["transform"].is_object()) {
    return false;  // no transform at all
  }
  const json& transform = clip["transform"];
  if (transform.value("framing", "fit") != "fit") return true;
  for (const auto& [key, value] : transform.items()) {
    if (value.is_object() && value.contains("keyframes")) return true;
  }
  RenderContext ctx;
  ctx.sequenceWidth = width;
  ctx.sequenceHeight = height;
  CompositedLayer layer;
  applyTransformJson(transform, RationalTime{}, ctx, &layer);
  // A corner pin (TRK-20/24) is a projective warp, so the clip is never a
  // frame the encoder can copy through untouched — even when its quad happens
  // to sit on the canvas edges.
  if (layer.corners) return true;
  return !(layer.x == 0.0 && layer.y == 0.0 && layer.scale == 1.0 &&
           layer.rotationDeg == 0.0 && layer.anchorX == 0.0 &&
           layer.anchorY == 0.0 && !layer.flipH && !layer.flipV &&
           layer.opacity >= 1.0);
}

// The lone visible clip at [time], or nullptr when there is none or more than
// one — either way there is compositing to do.
const json* soleVisibleClip(const RenderIndex& index, const RationalTime& time) {
  const json* only = nullptr;
  for (const auto& track : index.videoTracks()) {
    if (track.hidden) continue;
    const json* clip = index.clipAt(track, time);
    if (clip == nullptr) continue;
    if (only != nullptr) return nullptr;
    only = clip;
  }
  return only;
}

}  // namespace

std::set<std::string> passthroughClips(
    const RenderIndex& index, int width, int height,
    const std::function<std::optional<ClipSource>(const std::string&)>& resolve,
    const std::map<std::string, double>* exposureStops) {
  std::set<std::string> eligible;
  // Captions are composited above the video tracks. The worker's direct
  // decode/encode fast path cannot add overlays, so a captioned document must
  // stay on the shared compositor path. This deliberately favours correctness
  // over a per-cue fast-path toggle, which would visibly change video sampling
  // at cue boundaries.
  if (index.document().contains("captionTracks") &&
      index.document()["captionTracks"].is_array()) {
    for (const json& track : index.document()["captionTracks"]) {
      if (track.is_object() && !track.value("hidden", false) &&
          track.contains("items") && track["items"].is_array() &&
          !track["items"].empty()) {
        return eligible;
      }
    }
  }
  for (const auto& track : index.videoTracks()) {
    if (track.hidden) continue;
    for (const auto& span : track.clips) {
      const json& clip = *span.clip;
      const std::string clipId = clip.value("id", "");
      if (clipId.empty()) continue;
      if (index.transitionAsA(clipId) || index.transitionAsB(clipId)) continue;
      if (clip.value("mediaId", "").empty()) continue;  // text clip
      if (clip.contains("effects") && clip["effects"].is_array() &&
          !clip["effects"].empty()) {
        continue;
      }
      if (exposureStops != nullptr) {
        const auto it = exposureStops->find(clipId);
        if (it != exposureStops->end() && it->second != 0.0) continue;
      }
      const std::string blend = clip.value("blend", "normal");
      if (!blend.empty() && blend != "normal") continue;
      if (hasNonIdentityTransform(clip, width, height)) continue;

      // Anything else visible overlapping any part of this clip means it is
      // composited there, so it is composited everywhere.
      bool overlapped = false;
      for (const auto& other : index.videoTracks()) {
        if (other.hidden || &other == &track) continue;
        for (const auto& against : other.clips) {
          if (against.start < span.end && span.start < against.end) {
            overlapped = true;
            break;
          }
        }
        if (overlapped) break;
      }
      if (overlapped) continue;

      // It must resolve to a file the encoder can read frames from: no source
      // is the offline slate, and a texture is RGBA the caller already holds.
      const std::optional<ClipSource> src = resolve(clip.value("mediaId", ""));
      if (!src || src->path.empty() || !src->texture.rgba.empty()) continue;

      eligible.insert(clipId);
    }
  }
  return eligible;
}

std::optional<PassthroughFrame> passthroughFrameAt(
    const RenderIndex& index, const RationalTime& time,
    const std::set<std::string>& eligible,
    const std::function<std::optional<ClipSource>(const std::string&)>& resolve) {
  if (eligible.empty()) return std::nullopt;
  const json* only = soleVisibleClip(index, time);
  if (only == nullptr) return std::nullopt;
  const json& clip = *only;
  if (eligible.count(clip.value("id", "")) == 0) return std::nullopt;

  const auto start = parseJsonTime(clip.at("start"));
  if (!start) return std::nullopt;
  const RationalTime local = time - *start;

  const std::optional<ClipSource> src = resolve(clip.value("mediaId", ""));
  if (!src || src->path.empty()) return std::nullopt;

  double speed = 1.0;
  if (clip.contains("speed")) {
    const auto& s = clip["speed"];
    speed = s.is_object() ? static_cast<double>(s.value("num", 1)) /
                                std::max(1, s.value("den", 1))
                          : 1.0;
  }
  RationalTime sourceIn;
  if (clip.contains("sourceIn")) {
    if (const auto si = parseJsonTime(clip["sourceIn"])) sourceIn = *si;
  }

  PassthroughFrame out;
  out.path = src->path;
  out.sourceSeconds = sourceIn.toSeconds() + local.toSeconds() * speed;
  return out;
}

Error renderFrame(const json& document, const RationalTime& time, int width,
                  int height,
                  const std::function<std::optional<ClipSource>(
                      const std::string&)>& resolve,
                  RgbaSurface* out,
                  const std::map<std::string, double>* exposureStops) {
  // No index to reuse: this is a one-off frame, so build a throwaway one. It
  // costs what the old per-frame rescan cost.
  return renderFrame(RenderIndex(document), time, width, height, resolve, out,
                     exposureStops);
}

Error renderFrame(const RenderIndex& index, const RationalTime& time, int width,
                  int height,
                  const std::function<std::optional<ClipSource>(
                      const std::string&)>& resolve,
                  RgbaSurface* out,
                  const std::map<std::string, double>* exposureStops) {
  const json& document = index.document();
  if (!out) return Error::InvalidArgument;
  RenderContext ctx;
  ctx.sequenceWidth = width;
  ctx.sequenceHeight = height;
  {
    // Document size, so clip positions can be mapped from the document pixels
    // they are authored in into whatever canvas this call is rendering.
    const json* settings = document.contains("settings") &&
                                   document["settings"].is_object()
                               ? &document["settings"]
                               : nullptr;
    const int docW = settings ? settings->value("width", width) : width;
    const int docH = settings ? settings->value("height", height) : height;
    if (docW > 0) ctx.positionScaleX = static_cast<double>(width) / docW;
    if (docH > 0) ctx.positionScaleY = static_cast<double>(height) / docH;
  }

  // Background from settings (#RRGGBB).
  out->width = width;
  out->height = height;
  out->rgba.resize(static_cast<size_t>(width) * height * 4);
  {
    std::string bg = document.contains("settings")
                         ? document["settings"].value("background", "#000000")
                         : "#000000";
    if (!bg.empty() && bg[0] == '#') bg.erase(0, 1);
    uint8_t r = 0, g = 0, b = 0;
    auto byte = [&](size_t i) {
      auto nib = [](char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return 0;
      };
      return static_cast<uint8_t>(nib(bg[i]) * 16 + nib(bg[i + 1]));
    };
    if (bg.size() >= 6) { r = byte(0); g = byte(2); b = byte(4); }
    // Painting the background one channel at a time was two passes over a
    // multi-megabyte canvas every frame (the zero-fill above, then this).
    // Build the pixel once and splat it as 32-bit words.
    const uint8_t px[4] = {r, g, b, 255};
    uint32_t word;
    std::memcpy(&word, px, 4);
    uint32_t* p = reinterpret_cast<uint32_t*>(out->rgba.data());
    std::fill(p, p + static_cast<size_t>(width) * height, word);
  }

  for (const auto& track : index.videoTracks()) {
    if (track.hidden) continue;

    const json* here = index.clipAt(track, time);
    if (here == nullptr) continue;
    const json& clip = *here;

    // Transition span: this frame lies in A∩B. Find partner and blend.
    const std::string clipId = clip.value("id", "");
    const json* trans = nullptr;
    const json* partner = nullptr;
    bool incomingIsPartner = false;
    if (const json* asA = index.transitionAsA(clipId)) {
      trans = asA;
      incomingIsPartner = true;  // clip is A; partner is B
    } else if (const json* asB = index.transitionAsB(clipId)) {
      trans = asB;
      incomingIsPartner = false;  // clip is B; partner is A
    }
    if (trans) {
      partner = index.clipById(incomingIsPartner ? trans->value("bClipId", "")
                                                 : trans->value("aClipId", ""));
    }
    // Resolve sources for both sides.
    auto loadSide = [&](const json& side, RationalTime* localOut,
                        RgbaSurface* surf, CompositedLayer* layer) -> Error {
      const auto start = parseJsonTime(side.at("start"));
      const auto duration = parseJsonTime(side.at("duration"));
      if (!start || !duration) return Error::InternalError;
      *localOut = time - *start;
      const std::string mediaId = side.value("mediaId", "");
      // Text clips carry no media; the UI pushes their rasterized texture
      // through resolve() keyed by clip id (TXT-7).
      const std::string key =
          mediaId.empty() ? "text:" + side.value("id", "") : mediaId;
      std::optional<ClipSource> src = resolve(key);
      if (!src) {
        if (mediaId.empty()) {
          // Text clip with nothing rasterized yet (e.g. a typewriter reveal
          // before its first character): there is genuinely nothing to draw
          // this frame, not a missing asset. Composite nothing instead of
          // the offline slate, which reads as "media is broken".
          *surf = transparentSurface();
        } else {
          // The slate is what the user sees when a clip cannot find its
          // pixels. Say which clip and why, or the black-and-grey
          // checkerboard is the only evidence there is.
          CC_LOG_WARN("clip " + side.value("id", "") + ": no source for '" +
                      key + "' — drawing the offline slate");
          *surf = offlineSlate(ctx.sequenceWidth / 2, ctx.sequenceHeight / 2);
        }
      } else if (!src->texture.rgba.empty()) {
        *surf = src->texture;  // text/image texture path
      } else {
        double speed = 1.0;
        if (side.contains("speed")) {
          const auto& s = side["speed"];
          speed = s.is_object()
                      ? static_cast<double>(s.value("num", 1)) /
                            std::max(1, s.value("den", 1))
                      : 1.0;
        }
        RationalTime sourceIn;
        if (side.contains("sourceIn")) {
          if (const auto si = parseJsonTime(side["sourceIn"])) sourceIn = *si;
        }
        const double sourceSeconds =
            sourceIn.toSeconds() + localOut->toSeconds() * speed;
        const Error err = loadMediaFrame(src->path, sourceSeconds, ctx, surf);
        if (err != Error::None) {
          CC_LOG_WARN("clip " + side.value("id", "") + ": decode of " +
                      src->path + " at " + std::to_string(sourceSeconds) +
                      "s failed (" + lastError() + ") — drawing the offline slate");
          *surf = offlineSlate(ctx.sequenceWidth / 2, ctx.sequenceHeight / 2);
        }
      }

      const auto local = *localOut;
      applyTransformJson(side.contains("transform") ? side["transform"] : json(nullptr),
                         local, ctx, layer);

      // Effects stack: list order = application order, top applied first
      // (FX-1). We iterate forward so index 0 applies first.
      if (side.contains("effects")) {
        for (const auto& inst : side["effects"]) {
          auto resolved = resolveEffect(inst, local);
          if (!resolved) continue;
          applyEffect(*resolved, ctx, surf);
        }
      }

      // EXP-15: the export's exposure correction rides in after the user's
      // own grade so matching never fights their effect choices.
      if (exposureStops) {
        const auto it = exposureStops->find(side.value("id", ""));
        if (it != exposureStops->end() && it->second != 0.0) {
          applyExposureGain(surf, it->second);
        }
      }

      // Blend/opacity ride on the layer and are applied once at composite.
      layer->blend = side.value("blend", "normal");
      return Error::None;
    };

    // Render this clip fully (transform + effects + blend onto canvas).
    auto renderSide = [&](const json& side, RgbaSurface* canvas) -> Error {
      RationalTime local{};
      // Scratch surfaces live across frames: at sequence resolution these are
      // multi-megabyte buffers, and allocating them per clip per frame cost
      // more than the decode did. Reused within one thread, never held past
      // the call.
      thread_local RgbaSurface surfScratch;
      thread_local RgbaSurface renderedScratch;
      RgbaSurface* surf = &surfScratch;
      CompositedLayer layer;
      Error err = loadSide(side, &local, surf, &layer);
      if (err != Error::None) return err;
      const bool isText = side.value("mediaId", "").empty() &&
                          side.contains("text") && side["text"].is_object();
      std::string framing = isText ? "native" : "fit";
      if (!isText && side.contains("transform") &&
          side["transform"].is_object()) {
        framing = side["transform"].value("framing", "fit");
      }
      if (layer.opacity <= 0.0) return Error::None;

      // The normal playback path is already decoded at canvas width. Avoid a
      // second full-frame raster pass when no geometric transform is present.
      const bool passthrough =
          !layer.corners && surf->width == ctx.sequenceWidth &&
          surf->height == ctx.sequenceHeight && layer.x == 0.0 &&
          layer.y == 0.0 && layer.scale == 1.0 &&
          layer.rotationDeg == 0.0 && layer.anchorX == 0.0 &&
          layer.anchorY == 0.0 && !layer.flipH && !layer.flipV;
      if (passthrough) {
        blendComposite(canvas, *surf, layer.opacity, layer.blend);
        return Error::None;
      }
      LayerBounds bounds;
      err = rasterizeLayer(*surf, layer, ctx, framing, &renderedScratch, &bounds);
      if (err != Error::None) return err;
      blendComposite(canvas, renderedScratch, layer.opacity, layer.blend,
                     &bounds);
      return Error::None;
    };

    if (trans && partner) {
      const bool clipIsA = incomingIsPartner;  // `clip` is A, partner is B
      const json& sideA = clipIsA ? clip : *partner;
      const json& sideB = clipIsA ? *partner : clip;
      const auto aStart = parseJsonTime(sideA.at("start"));
      const auto bStart = parseJsonTime(sideB.at("start"));
      const auto aDur = parseJsonTime(sideA.at("duration"));
      const auto bDur = parseJsonTime(sideB.at("duration"));
      const auto tDur = parseJsonTime(trans->at("duration"));
      if (!aStart || !bStart || !aDur || !bDur || !tDur) continue;
      const RationalTime overlapStart =
          (*aStart > *bStart ? *aStart : *bStart).normalized();
      const RationalTime overlapEnd =
          ((*aStart + *aDur) < (*bStart + *bDur) ? (*aStart + *aDur)
                                                 : (*bStart + *bDur)).normalized();
      const double span = (overlapEnd - overlapStart).toSeconds();
      const double p =
          span > 0.0
              ? clampd((time - overlapStart).toSeconds() / span, 0.0, 1.0)
              : 0.0;

      // Both frames composited on black canvases, then blended by type.
      RgbaSurface frameA{ctx.sequenceWidth, ctx.sequenceHeight,
                         std::vector<uint8_t>(
                             static_cast<size_t>(ctx.sequenceWidth) *
                                 ctx.sequenceHeight * 4, 0)};
      frameA.rgba[3] = 255;  // opaque black base for each side
      for (size_t i = 0; i < frameA.rgba.size(); i += 4) {
        frameA.rgba[i + 3] = 255;
      }
      renderSide(sideA, &frameA);
      RgbaSurface frameB = frameA;
      std::fill(frameB.rgba.begin(), frameB.rgba.end(), 0);
      for (size_t i = 0; i < frameB.rgba.size(); i += 4) {
        frameB.rgba[i + 3] = 255;
      }
      renderSide(sideB, &frameB);

      RgbaSurface blended;
      if (compositeTransition(trans->value("type", "crossDissolve"),
                              trans->value("easing", "easeInOut"), p, frameA,
                              frameB, &blended) == Error::None) {
        blendComposite(out, blended, 1.0, "normal");
      }
    } else {
      Error err = renderSide(clip, out);
      (void)err;
    }
  }

  // Caption tracks are final sequence overlays. Flutter supplies the shaped
  // tight RGBA texture; this shared native path owns cue-boundary selection and
  // normalized placement, so preview and export cannot disagree.
  if (document.contains("captionTracks") &&
      document["captionTracks"].is_array()) {
    thread_local RgbaSurface captionScratch;
    for (const json& track : document["captionTracks"]) {
      if (!track.is_object() || track.value("hidden", false) ||
          !track.contains("items") || !track["items"].is_array()) {
        continue;
      }
      const json& style = track.contains("style") && track["style"].is_object()
                              ? track["style"]
                              : json::object();
      for (const json& item : track["items"]) {
        if (!item.is_object() || !item.contains("start") ||
            !item.contains("duration")) {
          continue;
        }
        const auto start = parseJsonTime(item["start"]);
        const auto duration = parseJsonTime(item["duration"]);
        if (!start || !duration || time < *start || time >= *start + *duration) {
          continue;
        }
        const std::string key = captionTextureKey(track, item, time);
        const std::optional<ClipSource> source = resolve(key);
        if (!source || source->texture.rgba.empty()) continue;

        CompositedLayer layer;
        layer.image = source->texture;
        layer.x = (clampd(style.value("positionX", 0.5), 0.0, 1.0) - 0.5) *
                  ctx.sequenceWidth;
        layer.y = (clampd(style.value("positionY", 0.88), 0.0, 1.0) - 0.5) *
                  ctx.sequenceHeight;
        LayerBounds bounds;
        const Error err = rasterizeLayer(source->texture, layer, ctx, "native",
                                         &captionScratch, &bounds);
        if (err != Error::None) return err;
        blendComposite(out, captionScratch, 1.0, "normal", &bounds);
      }
    }
  }
  return Error::None;
}

Error renderFrame(const json& document, const RationalTime& time, int width,
                  int height, const std::map<std::string, std::string>& assetPaths,
                  RgbaSurface* out,
                  const std::map<std::string, double>* exposureStops) {
  return renderFrame(
      document, time, width, height,
      [&](const std::string& assetId) -> std::optional<ClipSource> {
        const auto it = assetPaths.find(assetId);
        if (it == assetPaths.end()) return std::nullopt;
        ClipSource src;
        src.path = it->second;
        return src;
      },
      out, exposureStops);
}

std::map<std::string, double> measureClipLuma(
    const json& document, const std::map<std::string, std::string>& assetPaths,
    double startSec, double endSec, int samplesPerClip) {
  std::map<std::string, double> out;
  if (samplesPerClip < 1 || endSec <= startSec) return out;

  // Same visibility rules the renderer applies: video tracks in index order,
  // hidden tracks contribute nothing.
  const RenderIndex index(document);
  for (const auto& track : index.videoTracks()) {
    if (track.hidden) continue;
    for (const auto& span : track.clips) {
      const json& clip = *span.clip;
      const std::string mediaId = clip.value("mediaId", "");
      if (mediaId.empty()) continue;  // text clips have no source pixels
      const auto path = assetPaths.find(mediaId);
      if (path == assetPaths.end()) continue;

      const auto start = parseJsonTime(clip.at("start"));
      const auto duration = parseJsonTime(clip.at("duration"));
      if (!start || !duration) continue;
      RationalTime sourceIn;
      if (clip.contains("sourceIn")) {
        if (const auto si = parseJsonTime(clip["sourceIn"])) sourceIn = *si;
      }
      double speed = 1.0;
      if (clip.contains("speed")) {
        const auto& s = clip["speed"];
        speed = s.is_object()
                    ? static_cast<double>(s.value("num", 1)) /
                          std::max(1, s.value("den", 1))
                    : 1.0;
      }

      // Intersect the clip's timeline span with the measured window, then map
      // to source time — matching is computed from exactly what gets played.
      const double cStart = start->toSeconds();
      const double cEnd = cStart + duration->toSeconds();
      const double l0 = std::max(cStart, startSec);
      const double l1 = std::min(cEnd, endSec);
      if (l1 - l0 <= 0) continue;
      const double s0 = sourceIn.toSeconds() + (l0 - cStart) * speed;
      const double s1 = sourceIn.toSeconds() + (l1 - cStart) * speed;

      thread_local DecodedFrame frame;
      double sum = 0.0;
      int counted = 0;
      const std::string clipId = clip.value("id", "");
      for (int k = 0; k < samplesPerClip; ++k) {
        const double t =
            s0 + (s1 - s0) * (static_cast<double>(k) + 0.5) / samplesPerClip;
        // Small width: statistics do not need full resolution, and the
        // decoder session cache makes repeat seeks cheap.
        if (extractFrameRgba(path->second, t, 160, &frame) != Error::None) {
          break;
        }
        const double y = frameLuma(frame);
        if (y < 0.0) break;
        sum += y;
        ++counted;
      }
      if (counted > 0 && sum > 0.0) {
        out[clipId] = sum / static_cast<double>(counted);
      }
    }
  }
  return out;
}

std::map<std::string, double> computeExposureStops(
    const std::map<std::string, double>& clipLuma, double maxStops) {
  std::map<std::string, double> out;
  std::vector<double> values;
  for (const auto& [id, luma] : clipLuma) {
    (void)id;
    if (luma > 0.0) values.push_back(luma);
  }
  if (values.empty()) return out;
  std::sort(values.begin(), values.end());
  // Median target: the export keeps the project's overall exposure and only
  // pulls the outliers in line.
  const double median =
      values.size() % 2 == 1
          ? values[values.size() / 2]
          : 0.5 * (values[values.size() / 2 - 1] + values[values.size() / 2]);
  if (median <= 0.0) return out;
  maxStops = std::max(0.0, maxStops);
  for (const auto& [id, luma] : clipLuma) {
    if (luma <= 0.0) continue;
    out[id] = clampd(std::log2(median / luma), -maxStops, maxStops);
  }
  return out;
}

}  // namespace cc
