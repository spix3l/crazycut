#include "render/renderer.h"

#include <algorithm>
#include <cmath>

extern "C" {
#include <libavformat/avformat.h>
}

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
  out->rgba.assign(frame.rgba.begin(), frame.rgba.end());
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

}  // namespace

Error renderFrame(const json& document, const RationalTime& time, int width,
                  int height,
                  const std::function<std::optional<ClipSource>(
                      const std::string&)>& resolve,
                  RgbaSurface* out) {
  if (!out) return Error::InvalidArgument;
  RenderContext ctx;
  ctx.sequenceWidth = width;
  ctx.sequenceHeight = height;

  // Background from settings (#RRGGBB).
  out->width = width;
  out->height = height;
  out->rgba.assign(static_cast<size_t>(width) * height * 4, 0);
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
    for (size_t i = 0; i < out->rgba.size(); i += 4) {
      out->rgba[i] = r; out->rgba[i + 1] = g; out->rgba[i + 2] = b;
      out->rgba[i + 3] = 255;
    }
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
      std::optional<ClipSource> src =
          resolve(mediaId.empty() ? "text:" + side.value("id", "") : mediaId);
      if (!src) {
        *surf = offlineSlate(ctx.sequenceWidth / 2, ctx.sequenceHeight / 2);
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
        if (err != Error::None) *surf = offlineSlate(ctx.sequenceWidth / 2, ctx.sequenceHeight / 2);
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

      // Blend/opacity ride on the layer.
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
      std::string framing = "fit";
      if (side.contains("transform") && side["transform"].is_object()) {
        framing = side["transform"].value("framing", "fit");
      }
      err = rasterizeLayer(*surf, layer, ctx, framing, &renderedScratch);
      if (err != Error::None) return err;
      blendComposite(canvas, renderedScratch, layer.opacity, layer.blend);
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
                  RgbaSurface* out) {
  return renderFrame(
      document, time, width, height,
      [&](const std::string& assetId) -> std::optional<ClipSource> {
        const auto it = assetPaths.find(assetId);
        if (it == assetPaths.end()) return std::nullopt;
        ClipSource src;
        src.path = it->second;
        return src;
      },
      out);
}

}  // namespace cc
