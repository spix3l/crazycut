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

struct TrackInfo {
  std::string id;
  int index = 0;
  bool hidden = false;
  bool isVideo = true;
};

std::vector<TrackInfo> videoTrackOrder(const json& doc) {
  std::vector<TrackInfo> tracks;
  if (doc.contains("tracks") && doc["tracks"].is_array()) {
    for (const json& t : doc["tracks"]) {
      if (!t.is_object() || t.value("kind", "") != "video") continue;
      tracks.push_back({t.value("id", ""), t.value("index", 0),
                        t.value("hidden", false), true});
    }
  }
  std::stable_sort(tracks.begin(), tracks.end(),
                   [](const TrackInfo& a, const TrackInfo& b) {
                     return a.index < b.index;
                   });
  return tracks;
}

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

struct ClipRender {
  bool active = false;
  const json* clip = nullptr;
};

// Finds the clip on [trackId] covering [time], preferring the one bound to an
// active transition when two overlap.
ClipRender clipAt(const json& doc, const std::string& trackId,
                  const RationalTime& time) {
  ClipRender best;
  if (!doc.contains("clips") || !doc["clips"].is_array()) return best;
  for (const json& c : doc["clips"]) {
    if (!c.is_object() || c.value("trackId", "") != trackId) continue;
    const auto start = parseJsonTime(c.at("start"));
    const auto duration = parseJsonTime(c.at("duration"));
    if (!start || !duration) continue;
    if (time >= *start && time < *start + *duration) best = {true, &c};
  }
  return best;
}

const json* findTransition(const json& doc, const std::string& aId,
                           const std::string& bId) {
  if (!doc.contains("transitions") || !doc["transitions"].is_array()) return nullptr;
  for (const json& t : doc["transitions"]) {
    if (!t.is_object()) continue;
    if (t.value("aClipId", "") == aId && t.value("bClipId", "") == bId) return &t;
    if (t.value("aClipId", "") == bId && t.value("bClipId", "") == aId) return &t;
  }
  return nullptr;
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

Error renderFrame(const json& document, const RationalTime& time, int width,
                  int height,
                  const std::function<std::optional<ClipSource>(
                      const std::string&)>& resolve,
                  RgbaSurface* out,
                  const std::map<std::string, double>* exposureStops) {
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

  // Index transitions by clip for quick lookup.
  std::map<std::string, const json*> transA, transB;
  if (document.contains("transitions") && document["transitions"].is_array()) {
    for (const json& t : document["transitions"]) {
      if (!t.is_object()) continue;
      transA[t.value("aClipId", "")] = &t;
      transB[t.value("bClipId", "")] = &t;
    }
  }

  const auto tracks = videoTrackOrder(document);
  for (const auto& track : tracks) {
    if (track.hidden) continue;

    const ClipRender here = clipAt(document, track.id, time);
    if (!here.active || here.clip == nullptr) continue;
    const json& clip = *here.clip;

    // Transition span: this frame lies in A∩B. Find partner and blend.
    const std::string clipId = clip.value("id", "");
    const json* trans = nullptr;
    const json* partner = nullptr;
    bool incomingIsPartner = false;
    if (auto it = transA.find(clipId); it != transA.end()) {
      trans = it->second;
      incomingIsPartner = true;  // clip is A; partner is B
    } else if (auto it2 = transB.find(clipId); it2 != transB.end()) {
      trans = it2->second;
      incomingIsPartner = false;  // clip is B; partner is A
    }
    if (trans) {
      const std::string partnerId =
          incomingIsPartner ? trans->value("bClipId", "")
                            : trans->value("aClipId", "");
      if (document.contains("clips") && document["clips"].is_array()) {
        for (const json& c : document["clips"]) {
          if (c.is_object() && c.value("id", "") == partnerId) partner = &c;
        }
      }
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
          surf->width == ctx.sequenceWidth &&
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
  for (const auto& track : videoTrackOrder(document)) {
    if (track.hidden) continue;
    if (!document.contains("clips") || !document["clips"].is_array()) continue;
    for (const json& clip : document["clips"]) {
      if (!clip.is_object() || clip.value("trackId", "") != track.id) continue;
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
