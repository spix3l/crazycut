#pragma once

#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "core/result.h"
#include "render/effects.h"

namespace cc {

// A decoded source frame ready for compositing, with its own transform state
// applied (position/scale/rotation/anchor/opacity/flips — FX-9).
struct CompositedLayer {
  RgbaSurface image;      // straight-alpha RGBA in sequence colour space
  double x = 0.0;         // centre offset in sequence px
  double y = 0.0;
  double scale = 1.0;
  double rotationDeg = 0.0;
  double anchorX = 0.0;   // rotation/scale pivot inside the image, sequence px
  double anchorY = 0.0;
  double opacity = 1.0;   // 0..1
  bool flipH = false;
  bool flipV = false;

  // Blend mode against what is below (FX-12).
  std::string blend = "normal";
};

// Evaluates a ClipTransform JSON object at clip-local time into layer state.
// Missing keys fall back to defaults; the object may be absent entirely.
void applyTransformJson(const nlohmann::json& transform, const RationalTime& local,
                        const RenderContext& ctx, CompositedLayer* layer);

// Resamples [src] into a dstW×dstH buffer honouring framing ("fit" letterboxes,
// "fill" covers and crops centred, "stretch" ignores aspect), then applies the
// layer's position/scale/rotation/opacity. Output has the layer's footprint on
// the full sequence canvas: returned surface is sequence-sized with the layer
// drawn over transparency, ready for blendComposite().
Error rasterizeLayer(const RgbaSurface& src, const CompositedLayer& layer,
                     const RenderContext& ctx, const std::string& framing,
                     RgbaSurface* out);

// Alpha-over / blend [top] onto [base] in place using top.blend.
void blendComposite(RgbaSurface* base, const RgbaSurface& top, double opacity,
                    const std::string& blendMode);

// --- Transitions ------------------------------------------------------------

// Progress p in [0,1] eased per TRA-7.
double easeProgress(double p, const std::string& easing);

// Blends frame B (incoming) over frame A (outgoing) for transition type at p.
// dipToBlack/White render from/to the flat colour at the midpoint; slide/push/
// zoom move frames spatially. All operate on same-sized surfaces.
Error compositeTransition(const std::string& type, const std::string& easing,
                          double p, const RgbaSurface& a, const RgbaSurface& b,
                          RgbaSurface* out);

}  // namespace cc
