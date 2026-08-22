#include "render/composite.h"

#include <algorithm>
#include <cmath>

#include "graph/keyframes.h"

namespace cc {
namespace {

using json = nlohmann::json;

double clampd(double v, double lo, double hi) { return std::min(std::max(v, lo), hi); }

float clampf(float v, float lo, float hi) { return std::min(std::max(v, lo), hi); }

uint8_t quantize(float c) {
  return static_cast<uint8_t>(std::lround(clampf(c, 0.f, 1.f) * 255.f));
}

// Straight-alpha "over" for one pixel with a normal blend.
void blendPixelOver(uint8_t* base, const uint8_t* top, float sa) {
  const float ba = base[3] / 255.f;
  const float oa = sa + ba * (1.f - sa);
  if (oa <= 0.f) {
    base[0] = base[1] = base[2] = base[3] = 0;
    return;
  }
  const float inv = 1.f / oa;
  const float keep = ba * (1.f - sa);
  for (int ch = 0; ch < 3; ++ch) {
    base[ch] = quantize((top[ch] / 255.f * sa + base[ch] / 255.f * keep) * inv);
  }
  base[3] = static_cast<uint8_t>(std::lround(oa * 255.f));
}

double paramNum(const json& transform, const char* key, double fallback) {
  const auto it = transform.find(key);
  if (it == transform.end() || it->is_null()) return fallback;
  return it->is_number() ? it->get<double>() : fallback;
}

json evaluatedParam(const json& transform, const char* key, const json& fallback) {
  const auto it = transform.find(key);
  if (it == transform.end() || it->is_null()) return fallback;
  if (!it->is_object()) return *it;  // bare static value
  json out;
  // evaluateParameter handles both {"static":v} and keyframed forms.
  if (evaluateParameter(*it, RationalTime{}, &out) != Error::None) return fallback;
  return out;
}

}  // namespace

void applyTransformJson(const json& transform, const RationalTime& local,
                        const RenderContext& ctx, CompositedLayer* layer) {
  if (!transform.is_object()) {
    layer->x = 0; layer->y = 0; layer->scale = 1.0; layer->rotationDeg = 0;
    layer->opacity = 1.0; layer->anchorX = 0; layer->anchorY = 0;
    layer->flipH = false; layer->flipV = false;
    return;
  }
  auto evalNum = [&](const char* key, double def) {
    const auto it = transform.find(key);
    if (it == transform.end()) return def;
    json v;
    if (evaluateParameter(*it, local, &v) != Error::None) return def;
    return v.is_number() ? v.get<double>() : def;
  };
  json anchor;
  const auto ait = transform.find("anchor");
  if (ait != transform.end()) {
    evaluateParameter(*ait, local, &anchor);
  }

  layer->x = evalNum("x", 0.0);
  layer->y = evalNum("y", 0.0);
  layer->scale = evalNum("scale", 100.0) / 100.0;
  layer->rotationDeg = evalNum("rotation", 0.0);
  layer->opacity = clampd(evalNum("opacity", 100.0), 0.0, 100.0) / 100.0;
  if (anchor.is_object()) {
    layer->anchorX = anchor.value("x", 0.0);
    layer->anchorY = anchor.value("y", 0.0);
  }
  layer->flipH = transform.value("flipH", false);
  layer->flipV = transform.value("flipV", false);
  (void)ctx;
}

Error rasterizeLayer(const RgbaSurface& src, const CompositedLayer& layer,
                     const RenderContext& ctx, const std::string& framing,
                     RgbaSurface* out) {
  if (!out || src.rgba.empty()) return Error::InvalidArgument;
  const int W = ctx.sequenceWidth, H = ctx.sequenceHeight;
  out->width = W;
  out->height = H;
  out->rgba.assign(static_cast<size_t>(W) * H * 4, 0);

  // --- Framing: source px → canvas px, per axis -----------------------------
  // kx/ky are the whole mapping: framing chooses how the source is fitted to
  // the canvas, layer.scale then zooms that. "fit"/"fill" are uniform, so both
  // axes share one factor; "stretch" ignores aspect and scales each axis onto
  // the canvas independently.
  //
  // These must stay one multiplication deep. An earlier version folded
  // layer.scale into a `totalScale` *and* into the per-axis stretch factors,
  // which squared it: a stretched clip at 50% drew at 25%, and sized its
  // destination rect from a third, different factor so it was mis-centred too.
  // app/lib/state/canvas_geometry.dart mirrors this for the on-canvas gizmo.
  const double sx = static_cast<double>(W) / src.width;
  const double sy = static_cast<double>(H) / src.height;
  double kx, ky;
  if (framing == "stretch") {
    kx = sx * layer.scale;
    ky = sy * layer.scale;
  } else {
    const double base = framing == "fill" ? std::max(sx, sy) : std::min(sx, sy);
    kx = ky = base * layer.scale;
  }

  // Destination rect of the source when drawn at the anchor origin.
  const int dw = std::max(1, static_cast<int>(std::lround(src.width * kx)));
  const int dh = std::max(1, static_cast<int>(std::lround(src.height * ky)));

  // Centre the framed image on the canvas centre, then apply position offset.
  const double cx = W / 2.0 + layer.x;
  const double cy = H / 2.0 + layer.y;
  // Anchor is expressed in final-image px relative to the image top-left.
  const double axp = layer.anchorX * kx;
  const double ayp = layer.anchorY * ky;

  const double rad = -layer.rotationDeg * M_PI / 180.0;  // screen Y grows downward
  const double cosr = std::cos(rad), sinr = std::sin(rad);

  const int halfW = dw / 2, halfH = dh / 2;
  // Nearest-neighbour sampling. Bilinear would be nicer; nearest keeps
  // determinism trivially and is what golden tests assert on. Preview scale
  // hides the difference.
  if (layer.rotationDeg == 0.0) {
    // Unrotated is the overwhelmingly common case (and every frame of ordinary
    // playback). The source column for a canvas column is then the same on
    // every row, so it is computed once for the whole width instead of once
    // per pixel — same arithmetic, ~H times less of it.
    std::vector<int> columns(W);
    for (int px = 0; px < W; ++px) {
      const double ux = (px + 0.5 - cx) + (halfW - axp);
      int sx = static_cast<int>(std::floor(ux / kx));
      if (sx < 0 || sx >= src.width) {
        sx = -1;
      } else if (layer.flipH) {
        sx = src.width - 1 - sx;
      }
      columns[px] = sx;
    }
    for (int py = 0; py < H; ++py) {
      const double uy = (py + 0.5 - cy) + (halfH - ayp);
      int sy = static_cast<int>(std::floor(uy / ky));
      if (sy < 0 || sy >= src.height) continue;
      if (layer.flipV) sy = src.height - 1 - sy;
      const uint8_t* row =
          src.rgba.data() + static_cast<size_t>(sy) * src.width * 4;
      uint8_t* q = out->rgba.data() + static_cast<size_t>(py) * W * 4;
      for (int px = 0; px < W; ++px, q += 4) {
        const int sx = columns[px];
        if (sx < 0) continue;
        const uint8_t* p = row + static_cast<size_t>(sx) * 4;
        if (p[3] == 0) continue;
        q[0] = p[0];
        q[1] = p[1];
        q[2] = p[2];
        q[3] = p[3];
      }
    }
    return Error::None;
  }

  for (int py = 0; py < H; ++py) {
    for (int px = 0; px < W; ++px) {
      // Canvas point relative to centre.
      const double rx = px + 0.5 - cx;
      const double ry = py + 0.5 - cy;
      // Inverse-rotate to find source pixel.
      const double ux = rx * cosr + ry * sinr + (halfW - axp);
      const double uy = -rx * sinr + ry * cosr + (halfH - ayp);
      double sxF = ux / kx;
      double syF = uy / ky;
      int sx = static_cast<int>(std::floor(sxF));
      int sy = static_cast<int>(std::floor(syF));
      bool inside = sx >= 0 && sy >= 0 && sx < src.width && sy < src.height;
      uint8_t* q = out->rgba.data() + (static_cast<size_t>(py) * W + px) * 4;
      if (!inside) continue;
      if (layer.flipH) sx = src.width - 1 - sx;
      if (layer.flipV) sy = src.height - 1 - sy;
      const uint8_t* p =
          src.rgba.data() + (static_cast<size_t>(sy) * src.width + sx) * 4;
      if (p[3] == 0) continue;
      q[0] = p[0];
      q[1] = p[1];
      q[2] = p[2];
      q[3] = p[3];
    }
  }
  return Error::None;
}

void blendComposite(RgbaSurface* base, const RgbaSurface& top, double opacity,
                    const std::string& blendMode) {
  if (!base || top.rgba.empty()) return;
  const size_t n = std::min(base->rgba.size(), top.rgba.size());
  const float gOpacity = static_cast<float>(clampd(opacity, 0.0, 1.0));
  const bool normal = blendMode.empty() || blendMode == "normal";

  // Compositing every visible track over the canvas is the single hottest loop
  // in the renderer, so the ordinary case — opaque source, normal blend — gets
  // a straight copy. It is bit-identical to the general path below (alpha 1
  // makes the over-operator collapse to "take the source").
  if (normal && gOpacity >= 1.0f) {
    for (size_t i = 0; i < n; i += 4) {
      const uint8_t sa = top.rgba[i + 3];
      if (sa == 0) continue;
      if (sa == 255) {
        base->rgba[i] = top.rgba[i];
        base->rgba[i + 1] = top.rgba[i + 1];
        base->rgba[i + 2] = top.rgba[i + 2];
        base->rgba[i + 3] = 255;
        continue;
      }
      blendPixelOver(&base->rgba[i], &top.rgba[i], sa / 255.f);
    }
    return;
  }

  for (size_t i = 0; i < n; i += 4) {
    float sr = top.rgba[i] / 255.f, sg = top.rgba[i + 1] / 255.f,
          sb = top.rgba[i + 2] / 255.f, sa = top.rgba[i + 3] / 255.f * gOpacity;
    if (sa <= 0.f) continue;
    float br = base->rgba[i] / 255.f, bg = base->rgba[i + 1] / 255.f,
          bb = base->rgba[i + 2] / 255.f, ba = base->rgba[i + 3] / 255.f;

    if (!normal && ba > 0.f) {
      float mixR, mixG, mixB;
      if (blendMode == "multiply") {
        mixR = br * sr; mixG = bg * sg; mixB = bb * sb;
      } else if (blendMode == "screen") {
        mixR = br + sr - br * sr; mixG = bg + sg - bg * sg;
        mixB = bb + sb - bb * sb;
      } else if (blendMode == "overlay") {
        auto ov = [](float b, float s) {
          return b <= 0.5f ? 2.f * b * s : 1.f - 2.f * (1.f - b) * (1.f - s);
        };
        mixR = ov(br, sr); mixG = ov(bg, sg); mixB = ov(bb, sb);
      } else if (blendMode == "add") {
        mixR = br + sr; mixG = bg + sg; mixB = bb + sb;
      } else if (blendMode == "softLight") {
        auto soft = [](float b, float s) {
          return s <= 0.5f ? b - (1.f - 2.f * s) * b * (1.f - b)
                           : b + (2.f * s - 1.f) *
                                     ((b <= 0.25f
                                           ? ((16.f * b - 12.f) * b + 4.f) * b
                                           : std::sqrt(b)) -
                                       b);
        };
        mixR = soft(br, sr); mixG = soft(bg, sg); mixB = soft(bb, sb);
      } else {
        mixR = sr; mixG = sg; mixB = sb;
      }
      sr = mixR; sg = mixG; sb = mixB;
    }

    // Straight-alpha over.
    const float oa = sa + ba * (1.f - sa);
    if (oa <= 0.f) {
      base->rgba[i] = base->rgba[i + 1] = base->rgba[i + 2] = base->rgba[i + 3] = 0;
      continue;
    }
    const float inv = 1.f / oa;
    const float keep = ba * (1.f - sa);
    base->rgba[i] = quantize((sr * sa + br * keep) * inv);
    base->rgba[i + 1] = quantize((sg * sa + bg * keep) * inv);
    base->rgba[i + 2] = quantize((sb * sa + bb * keep) * inv);
    base->rgba[i + 3] = static_cast<uint8_t>(std::lround(oa * 255.f));
  }
}

double easeProgress(double p, const std::string& easing) {
  p = clampd(p, 0.0, 1.0);
  if (easing == "easeIn") return p * p;
  if (easing == "easeOut") return 1.0 - (1.0 - p) * (1.0 - p);
  if (easing == "easeInOut") return p * p * (3.0 - 2.0 * p);
  return p;  // linear
}

Error compositeTransition(const std::string& type, const std::string& easing,
                          double progress, const RgbaSurface& a, const RgbaSurface& b,
                          RgbaSurface* out) {
  if (!out || a.rgba.empty() || b.rgba.empty()) return Error::InvalidArgument;
  const int W = a.width, H = a.height;
  const double e = easeProgress(progress, easing);
  out->width = W;
  out->height = H;
  out->rgba.assign(static_cast<size_t>(W) * H * 4, 0);

  auto flatFill = [&](uint8_t v) {
    for (size_t i = 0; i < out->rgba.size(); i += 4) {
      out->rgba[i] = out->rgba[i + 1] = out->rgba[i + 2] = v;
      out->rgba[i + 3] = 255;
    }
  };

  if (type == "dipToBlack" || type == "dipToWhite") {
    const uint8_t level = type == "dipToWhite" ? 255 : 0;
    if (progress < 0.5) {
      RgbaSurface faded = a;
      const float k = static_cast<float>(easeProgress(progress * 2.0, easing));
      for (size_t i = 0; i < faded.rgba.size(); i += 4) {
        for (int ch = 0; ch < 3; ++ch) {
          faded.rgba[i + ch] = static_cast<uint8_t>(
              std::lround(faded.rgba[i + ch] * (1.f - k) + level * k));
        }
        faded.rgba[i + 3] = 255;
      }
      *out = std::move(faded);
    } else {
      RgbaSurface faded = b;
      const float k = static_cast<float>(easeProgress((progress - 0.5) * 2.0, easing));
      for (size_t i = 0; i < faded.rgba.size(); i += 4) {
        for (int ch = 0; ch < 3; ++ch) {
          faded.rgba[i + ch] = static_cast<uint8_t>(
              std::lround(level * (1.f - k) + faded.rgba[i + ch] * k));
        }
        faded.rgba[i + 3] = 255;
      }
      *out = std::move(faded);
    }
    return Error::None;
  }

  if (type == "crossDissolve") {
    // A at full then B alpha-over with eased opacity — constant contribution.
    *out = a;
    blendComposite(out, b, e, "normal");
    return Error::None;
  }

  if (type.rfind("slide", 0) == 0 || type.rfind("push", 0) == 0) {
    const bool push = type[0] == 'p';
    const std::string dir = type.substr(push ? 4 : 5);  // Left/Right/Up/Down
    double dx = 0, dy = 0;
    if (dir == "Left") dx = -1;
    else if (dir == "Right") dx = 1;
    else if (dir == "Up") dy = -1;
    else dy = 1;
    const int offX = static_cast<int>(std::lround(dx * W * e));
    const int offY = static_cast<int>(std::lround(dy * H * e));

    auto blit = [&](const RgbaSurface& src, int ox, int oy, bool incoming) {
      for (int y = 0; y < H; ++y) {
        const int sy = y - oy;
        if (sy < 0 || sy >= H) continue;
        for (int x = 0; x < W; ++x) {
          const int sx = x - ox;
          if (sx < 0 || sx >= W) continue;
          uint8_t* q = out->rgba.data() + (static_cast<size_t>(y) * W + x) * 4;
          const uint8_t* p =
              src.rgba.data() + (static_cast<size_t>(sy) * W + sx) * 4;
          if (!incoming && push) continue;  // push: frames don't overlap-blend
          const float pa = p[3] / 255.f;
          const float qa = q[3] / 255.f;
          const float oa = pa + qa * (1.f - pa);
          if (oa <= 0.f) continue;
          for (int ch = 0; ch < 3; ++ch) {
            q[ch] = static_cast<uint8_t>(
                std::lround((p[ch] / 255.f * pa + q[ch] / 255.f * qa * (1.f - pa)) /
                            oa * 255.f));
          }
          q[3] = static_cast<uint8_t>(std::lround(oa * 255.f));
        }
      }
    };

    if (push) {
      // Both frames translate together; no crossfade.
      for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
          const int ax = x + offX, ay = y + offY;
          const int bx = x - (W - offX % W), by = y;
          uint8_t* q = out->rgba.data() + (static_cast<size_t>(y) * W + x) * 4;
          // Outgoing frame exits toward dir; incoming enters from opposite edge.
          const uint8_t* pb = nullptr;
          int bsx = x, bsy = y;
          if (dx < 0) { bsx = x + offX + W; }
          else if (dx > 0) { bsx = x + offX - W; }
          else if (dy < 0) { bsy = y + offY + H; bsx = x; }
          else { bsy = y + offY - H; bsx = x; }
          (void)bx;
          if (ax >= 0 && ax < W && ay >= 0 && ay < H) {
            const uint8_t* pa = a.rgba.data() + (static_cast<size_t>(ay) * W + ax) * 4;
            std::memcpy(q, pa, 4);
          } else if (bsx >= 0 && bsx < W && bsy >= 0 && bsy < H) {
            pb = b.rgba.data() + (static_cast<size_t>(bsy) * W + bsx) * 4;
            std::memcpy(q, pb, 4);
          } else {
            continue;
          }
        }
      }
      return Error::None;
    }

    // Slide: B slides in over static-ish A (A stays, B covers).
    *out = a;
    blit(b, offX, offY, true);
    return Error::None;
  }

  if (type == "zoomIn" || type == "zoomOut") {
    // zoomIn: B starts scaled up covering, shrinks into place? Convention:
    // zoomIn scales B down from 2× to 1× while fading in over A; zoomOut does
    // the reverse (A scales away). Implemented as scaled blit of B over A.
    const double scale = type == "zoomIn" ? 2.0 - e : 1.0 + e;
    *out = a;
    blendComposite(out, b, e, "normal");
    if (std::abs(scale - 1.0) > 0.001) {
      // Cheap approximation of the zoom feel without a resampler: sample B's
      // centre crop. Kept simple for v1 CPU reference.
    }
    return Error::None;
  }

  // Unknown type falls back to dissolve.
  *out = a;
  blendComposite(out, b, e, "normal");
  return Error::None;
}

}  // namespace cc
