#pragma once

#include <array>
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

  // Corner pin (TRK-20): the destination quad in render-canvas px, TL/TR/BR/BL.
  // A perspective quad cannot be expressed by one uniform `scale` plus a roll,
  // so when this is set it *supersedes* x/y/scale/rotationDeg/anchor entirely
  // and the layer is warped through the homography that maps its framed rect
  // onto this quad. flipH/flipV, opacity and blend still apply.
  std::optional<std::array<double, 8>> corners;

  // Blend mode against what is below (FX-12).
  std::string blend = "normal";
};

// Evaluates a ClipTransform JSON object at clip-local time into layer state.
// Missing keys fall back to defaults; the object may be absent entirely.
void applyTransformJson(const nlohmann::json& transform, const RationalTime& local,
                        const RenderContext& ctx, CompositedLayer* layer);

// The canvas rectangle a rasterized layer actually wrote into, inclusive on
// both ends. Everything outside it is transparent, so the composite pass can
// skip it instead of walking the whole canvas for a layer that covers a
// corner of it.
struct LayerBounds {
  int x0 = 0, y0 = 0, x1 = -1, y1 = -1;
  bool empty() const { return x1 < x0 || y1 < y0; }
};

// Resamples [src] into a dstW×dstH buffer honouring framing ("fit" letterboxes,
// "fill" covers and crops centred, "stretch" ignores aspect), then applies the
// layer's position/scale/rotation. Output has the layer's footprint on the full
// sequence canvas with its source alpha intact; opacity and blend mode are
// applied once by blendComposite().
//
// [outBounds], when given, receives the footprint that was written.
Error rasterizeLayer(const RgbaSurface& src, const CompositedLayer& layer,
                     const RenderContext& ctx, const std::string& framing,
                     RgbaSurface* out, LayerBounds* outBounds = nullptr);

// Alpha-over / blend [top] onto [base] in place using top.blend. [bounds], when
// given, restricts the pass to the rows and columns [top] actually covers —
// everything else in it is transparent and would be skipped pixel by pixel.
void blendComposite(RgbaSurface* base, const RgbaSurface& top, double opacity,
                    const std::string& blendMode,
                    const LayerBounds* bounds = nullptr);

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
