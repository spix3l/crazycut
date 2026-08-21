#pragma once

#include <map>
#include <optional>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "core/result.h"
#include "core/time.h"
#include "render/composite.h"
#include "render/effects.h"

namespace cc {

// A media source resolved for one clip: either a file path (video/image) or a
// caller-supplied RGBA texture (text rasterized by the UI — TXT-7).
struct ClipSource {
  std::string path;       // empty when texture is set
  RgbaSurface texture;    // pre-rasterized text/image layer
  bool hasAudio = false;
};

// One frame request: which clip, what sequence time, where its source lives.
struct ClipFrameRequest {
  std::string clipId;
  nlohmann::json clip;        // full clip JSON from the snapshot
  ClipSource* source = nullptr;
};

// Renders one composited frame of a validated project document at [time].
//
// The document must have passed ProjectSnapshot::load (clips/transitions
// valid). Media sources are provided by the caller via [resolve], which maps
// an asset id to a ClipSource; returning nullopt renders the offline slate.
//
// Pipeline per architecture §7:
//   per video track (bottom → top): clip decode → conform → transform →
//   effects stack → blend onto accumulator; transition spans blend the two
//   clips through compositeTransition(); text layers arrive as textures and
//   flow through identical transform/effect machinery.
Error renderFrame(const nlohmann::json& document, const RationalTime& time,
                  int width, int height,
                  const std::function<std::optional<ClipSource>(
                      const std::string& assetId)>& resolve,
                  RgbaSurface* out);

// Convenience: renders against a map of asset id → path.
Error renderFrame(const nlohmann::json& document, const RationalTime& time,
                  int width, int height,
                  const std::map<std::string, std::string>& assetPaths,
                  RgbaSurface* out);

}  // namespace cc
