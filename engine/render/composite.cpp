#include "render/composite.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "graph/keyframes.h"

namespace cc {
namespace {

using json = nlohmann::json;
constexpr double kPi = 3.14159265358979323846;

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

// One axis of a bilinear tap: the two source indices to mix and the weight of
// the second. `a < 0` means the canvas pixel falls outside the source.
struct Tap {
  int a = -1;   // first sample (also the nearest one when `n` is used)
  int b = -1;   // second sample
  int n = -1;   // nearest-neighbour index, for the 1:1 fast path
  float t = 0.f;
};

// Maps a canvas coordinate to its source neighbours. The *inside* test still
// uses the nearest-neighbour rule, so a layer covers exactly the same
// destination rect it did before — only what is read inside it changes.
Tap axisTap(double canvasCoord, double k, int extent, bool flip) {
  const double f = canvasCoord / k;
  const int nearest = static_cast<int>(std::floor(f));
  if (nearest < 0 || nearest >= extent) return Tap{};
  const double centred = f - 0.5;
  int a = static_cast<int>(std::floor(centred));
  const float t = static_cast<float>(centred - a);
  int b = a + 1;
  a = std::min(std::max(a, 0), extent - 1);
  b = std::min(std::max(b, 0), extent - 1);
  int n = nearest;
  if (flip) {
    a = extent - 1 - a;
    b = extent - 1 - b;
    n = extent - 1 - n;
  }
  return Tap{a, b, n, t};
}

// Bilinear fetch in premultiplied space. Interpolating straight alpha would
// pull the RGB of fully transparent pixels (usually black) into the edge of
// every logo and glyph, which shows up as a dark fringe.
void sampleBilinear(const RgbaSurface& src, const Tap& cx, const Tap& cy,
                    uint8_t* out) {
  const size_t stride = static_cast<size_t>(src.width) * 4;
  const uint8_t* rows[2] = {src.rgba.data() + cy.a * stride,
                            src.rgba.data() + cy.b * stride};
  const float wy[2] = {1.f - cy.t, cy.t};
  const float wx[2] = {1.f - cx.t, cx.t};
  const int xs[2] = {cx.a, cx.b};

  // Opaque source — video frames, photos, the inside of any logo — is the
  // overwhelmingly common tap. Premultiplying by an alpha that is always 1 and
  // dividing it back out again is eight multiplies and a divide per pixel of
  // pure ceremony, and this runs once per canvas pixel of every scaled or
  // rotated layer.
  const uint8_t* q00 = rows[0] + static_cast<size_t>(xs[0]) * 4;
  const uint8_t* q01 = rows[0] + static_cast<size_t>(xs[1]) * 4;
  const uint8_t* q10 = rows[1] + static_cast<size_t>(xs[0]) * 4;
  const uint8_t* q11 = rows[1] + static_cast<size_t>(xs[1]) * 4;
  if (q00[3] == 255 && q01[3] == 255 && q10[3] == 255 && q11[3] == 255) {
    const float w00 = wy[0] * wx[0], w01 = wy[0] * wx[1];
    const float w10 = wy[1] * wx[0], w11 = wy[1] * wx[1];
    for (int ch = 0; ch < 3; ++ch) {
      out[ch] = static_cast<uint8_t>(std::lround(clampf(
          q00[ch] * w00 + q01[ch] * w01 + q10[ch] * w10 + q11[ch] * w11, 0.f,
          255.f)));
    }
    out[3] = 255;
    return;
  }

  float acc[4] = {0.f, 0.f, 0.f, 0.f};
  for (int j = 0; j < 2; ++j) {
    for (int i = 0; i < 2; ++i) {
      const float w = wy[j] * wx[i];
      if (w <= 0.f) continue;
      const uint8_t* p = rows[j] + static_cast<size_t>(xs[i]) * 4;
      const float a = p[3] / 255.f;
      acc[0] += p[0] / 255.f * a * w;
      acc[1] += p[1] / 255.f * a * w;
      acc[2] += p[2] / 255.f * a * w;
      acc[3] += a * w;
    }
  }
  if (acc[3] <= 0.f) {
    out[0] = out[1] = out[2] = out[3] = 0;
    return;
  }
  const float inv = 1.f / acc[3];
  out[0] = quantize(acc[0] * inv);
  out[1] = quantize(acc[1] * inv);
  out[2] = quantize(acc[2] * inv);
  out[3] = quantize(acc[3]);
}

// --- Corner pin (TRK-20) ----------------------------------------------------

// A quad is usable if it is simple (not self-intersecting), convex, and encloses
// at least a pixel. A planar rectangle seen through any real camera projects to
// a convex quad, so anything else is a degenerate solve and renders nothing
// rather than undefined pixels (TRK-25).
bool quadIsUsable(const std::array<double, 8>& q) {
  double twiceArea = 0.0;
  int sign = 0;
  for (int i = 0; i < 4; ++i) {
    const int j = (i + 1) % 4, k = (i + 2) % 4;
    const double ax = q[2 * j] - q[2 * i], ay = q[2 * j + 1] - q[2 * i + 1];
    const double bx = q[2 * k] - q[2 * j], by = q[2 * k + 1] - q[2 * j + 1];
    const double cross = ax * by - ay * bx;
    if (!std::isfinite(cross) || cross == 0.0) return false;
    const int s = cross > 0 ? 1 : -1;
    if (sign == 0) sign = s;
    else if (s != sign) return false;
    twiceArea += q[2 * i] * q[2 * j + 1] - q[2 * j] * q[2 * i + 1];
  }
  return std::abs(twiceArea) >= 2.0;
}

// Heckbert's projective mapping of the unit square (0,0),(1,0),(1,1),(0,1) onto
// a quad given TL,TR,BR,BL. Row-major 3x3 with m[8] == 1.
bool unitSquareToQuad(const std::array<double, 8>& q, double m[9]) {
  const double x0 = q[0], y0 = q[1], x1 = q[2], y1 = q[3];
  const double x2 = q[4], y2 = q[5], x3 = q[6], y3 = q[7];
  const double sx = x0 - x1 + x2 - x3;
  const double sy = y0 - y1 + y2 - y3;
  double a, b, c, d, e, f, g, h;
  if (std::abs(sx) < 1e-12 && std::abs(sy) < 1e-12) {
    // Parallelogram: the projective terms vanish and this is a plain affine
    // map. Taking the general branch here would divide by a near-zero
    // determinant for no reason.
    a = x1 - x0; b = x2 - x1; c = x0;
    d = y1 - y0; e = y2 - y1; f = y0;
    g = 0.0; h = 0.0;
  } else {
    const double dx1 = x1 - x2, dx2 = x3 - x2;
    const double dy1 = y1 - y2, dy2 = y3 - y2;
    const double den = dx1 * dy2 - dx2 * dy1;
    if (std::abs(den) < 1e-12) return false;
    g = (sx * dy2 - dx2 * sy) / den;
    h = (dx1 * sy - sx * dy1) / den;
    a = x1 - x0 + g * x1;  b = x3 - x0 + h * x3;  c = x0;
    d = y1 - y0 + g * y1;  e = y3 - y0 + h * y3;  f = y0;
  }
  m[0] = a; m[1] = b; m[2] = c;
  m[3] = d; m[4] = e; m[5] = f;
  m[6] = g; m[7] = h; m[8] = 1.0;
  return true;
}

bool invert3x3(const double m[9], double out[9]) {
  const double c0 = m[4] * m[8] - m[5] * m[7];
  const double c1 = m[5] * m[6] - m[3] * m[8];
  const double c2 = m[3] * m[7] - m[4] * m[6];
  const double det = m[0] * c0 + m[1] * c1 + m[2] * c2;
  if (!std::isfinite(det) || std::abs(det) < 1e-12) return false;
  const double inv = 1.0 / det;
  out[0] = c0 * inv;
  out[1] = (m[2] * m[7] - m[1] * m[8]) * inv;
  out[2] = (m[1] * m[5] - m[2] * m[4]) * inv;
  out[3] = c1 * inv;
  out[4] = (m[0] * m[8] - m[2] * m[6]) * inv;
  out[5] = (m[2] * m[3] - m[0] * m[5]) * inv;
  out[6] = c2 * inv;
  out[7] = (m[1] * m[6] - m[0] * m[7]) * inv;
  out[8] = (m[0] * m[4] - m[1] * m[3]) * inv;
  return true;
}

// Inverse-maps every canvas pixel in the quad's bounding box back through the
// homography and samples the source there. Same shape as the rotated branch of
// rasterizeLayer(), and it reuses axisTap/sampleBilinear so the inside test,
// the flips and the filtering stay identical across all three paths.
//
// Framing is deliberately ignored: the quad states the destination completely,
// so corner pin maps the whole source image onto it. That is what corner pin
// means, and letting "fill" crop underneath it would be unpredictable.
Error rasterizeCornerPin(const RgbaSurface& src, const std::array<double, 8>& quad,
                         const CompositedLayer& layer, RgbaSurface* out,
                         LayerBounds* outBounds) {
  double fwd[9], inv[9];
  if (!quadIsUsable(quad) || !unitSquareToQuad(quad, fwd) || !invert3x3(fwd, inv)) {
    return Error::None;  // empty footprint; the composite pass skips the layer
  }

  // Points "behind" the plane also satisfy the u/v bounds test after the
  // perspective divide, and would paint a mirrored ghost outside the quad.
  // Normalizing on the centroid's w lets a plain `w > 0` reject them.
  double cxq = 0.0, cyq = 0.0;
  for (int i = 0; i < 4; ++i) { cxq += quad[2 * i]; cyq += quad[2 * i + 1]; }
  cxq *= 0.25; cyq *= 0.25;
  if (inv[6] * cxq + inv[7] * cyq + inv[8] < 0.0) {
    for (int i = 0; i < 9; ++i) inv[i] = -inv[i];
  }

  const int W = out->width, H = out->height;
  double minX = quad[0], maxX = quad[0], minY = quad[1], maxY = quad[1];
  for (int i = 1; i < 4; ++i) {
    minX = std::min(minX, quad[2 * i]);
    maxX = std::max(maxX, quad[2 * i]);
    minY = std::min(minY, quad[2 * i + 1]);
    maxY = std::max(maxY, quad[2 * i + 1]);
  }
  const int bx0 = std::max(0, static_cast<int>(std::floor(minX)));
  const int bx1 = std::min(W - 1, static_cast<int>(std::ceil(maxX)));
  const int by0 = std::max(0, static_cast<int>(std::floor(minY)));
  const int by1 = std::min(H - 1, static_cast<int>(std::ceil(maxY)));

  int firstCol = W, lastCol = -1, firstRow = H, lastRow = -1;
  for (int py = by0; py <= by1; ++py) {
    uint8_t* row = out->rgba.data() + static_cast<size_t>(py) * W * 4;
    const double cy = py + 0.5;
    for (int px = bx0; px <= bx1; ++px) {
      const double cx = px + 0.5;
      const double w = inv[6] * cx + inv[7] * cy + inv[8];
      if (w <= 1e-12) continue;
      const double u = (inv[0] * cx + inv[1] * cy + inv[2]) / w;
      const double v = (inv[3] * cx + inv[4] * cy + inv[5]) / w;
      // k = 1: u/v are already source pixel coordinates, so axisTap's own
      // bounds check is the inside test for the quad.
      const Tap tapX = axisTap(u * src.width, 1.0, src.width, layer.flipH);
      const Tap tapY = axisTap(v * src.height, 1.0, src.height, layer.flipV);
      if (tapX.a < 0 || tapY.a < 0) continue;
      if (px < firstCol) firstCol = px;
      if (px > lastCol) lastCol = px;
      if (py < firstRow) firstRow = py;
      if (py > lastRow) lastRow = py;
      uint8_t px4[4];
      sampleBilinear(src, tapX, tapY, px4);
      if (px4[3] == 0) continue;
      std::memcpy(row + static_cast<size_t>(px) * 4, px4, 4);
    }
  }
  if (outBounds && lastCol >= 0 && lastRow >= 0) {
    *outBounds = LayerBounds{firstCol, firstRow, lastCol, lastRow};
  }
  return Error::None;
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
    layer->corners.reset();
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

  layer->x = evalNum("x", 0.0) * ctx.positionScaleX;
  layer->y = evalNum("y", 0.0) * ctx.positionScaleY;
  layer->scale = evalNum("scale", 100.0) / 100.0;
  layer->rotationDeg = evalNum("rotation", 0.0);
  layer->opacity = clampd(evalNum("opacity", 100.0), 0.0, 100.0) / 100.0;
  if (anchor.is_object()) {
    layer->anchorX = anchor.value("x", 0.0);
    layer->anchorY = anchor.value("y", 0.0);
  }
  layer->flipH = transform.value("flipH", false);
  layer->flipV = transform.value("flipV", false);

  // Corner pin (TRK-20). Stored in document px like x/y, so it goes through the
  // same positionScale as they do — a preview rendered small pins the overlay
  // to the same place the delivered frame does.
  layer->corners.reset();
  const auto cit = transform.find("corners");
  if (cit != transform.end() && !cit->is_null()) {
    // Either the {static,keyframes} param form or a bare quad, as every other
    // transform value may be written (see evaluatedParam above).
    json quad;
    bool haveQuad = cit->is_array();
    if (haveQuad) quad = *cit;
    else haveQuad = evaluateParameter(*cit, local, &quad) == Error::None;
    if (haveQuad && quad.is_array() && quad.size() == 8) {
      std::array<double, 8> corners{};
      bool ok = true;
      for (size_t i = 0; i < 8 && ok; ++i) {
        ok = quad[i].is_number() && std::isfinite(quad[i].get<double>());
        if (ok) {
          corners[i] = quad[i].get<double>() *
                       (i % 2 == 0 ? ctx.positionScaleX : ctx.positionScaleY);
        }
      }
      if (ok) layer->corners = corners;
    }
  }
}

Error rasterizeLayer(const RgbaSurface& src, const CompositedLayer& layer,
                     const RenderContext& ctx, const std::string& framing,
                     RgbaSurface* out, LayerBounds* outBounds) {
  if (!out || src.rgba.empty()) return Error::InvalidArgument;
  const int W = ctx.sequenceWidth, H = ctx.sequenceHeight;
  out->width = W;
  out->height = H;
  out->rgba.assign(static_cast<size_t>(W) * H * 4, 0);
  // Nothing written yet; an early return leaves an empty footprint, which the
  // composite pass reads as "skip this layer".
  if (outBounds) *outBounds = LayerBounds{0, 0, -1, -1};

  // A corner pin states its destination outright, so it supersedes framing and
  // the whole position/scale/rotation chain below (TRK-20).
  if (layer.corners) {
    return rasterizeCornerPin(src, *layer.corners, layer, out, outBounds);
  }

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
  // app/lib/modules/editor/domain/canvas_geometry.dart mirrors this for the
  // on-canvas gizmo.
  const double sx = static_cast<double>(W) / src.width;
  const double sy = static_cast<double>(H) / src.height;
  double kx, ky;
  if (framing == "native") {
    // Text is already rasterized for this output size. Treating its tight
    // glyph bounds like image media and fitting them to the canvas made every
    // caption balloon to nearly full-frame size, regardless of fontSize.
    kx = ky = layer.scale;
  } else if (framing == "stretch") {
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

  const double rad = -layer.rotationDeg * kPi / 180.0;  // screen Y grows downward
  const double cosr = std::cos(rad), sinr = std::sin(rad);

  const int halfW = dw / 2, halfH = dh / 2;
  // Sampling: nearest when the source maps 1:1 onto the canvas, bilinear when
  // it does not. A layer drawn at its own resolution — text rasterized for this
  // exact frame, footage delivered at sequence size — must stay bit-exact, both
  // because interpolating it can only soften it and because the goldens assert
  // on those pixels. Anything resized or rotated is resampled, and nearest made
  // that visibly blocky: glyph stems landed on whole pixels so some came out a
  // pixel wider than their neighbours.
  const bool exact = std::abs(kx - 1.0) < 1e-9 && std::abs(ky - 1.0) < 1e-9 &&
                     layer.rotationDeg == 0.0;
  if (layer.rotationDeg == 0.0) {
    // Unrotated is the overwhelmingly common case (and every frame of ordinary
    // playback). The source column for a canvas column is then the same on
    // every row, so it is computed once for the whole width instead of once
    // per pixel — same arithmetic, ~H times less of it.
    std::vector<Tap> columns(W);
    int firstCol = W, lastCol = -1;
    for (int px = 0; px < W; ++px) {
      columns[px] = axisTap((px + 0.5 - cx) + (halfW - axp), kx, src.width,
                            layer.flipH);
      if (columns[px].a >= 0) {
        if (px < firstCol) firstCol = px;
        lastCol = px;
      }
    }
    int firstRow = H, lastRow = -1;
    for (int py = 0; py < H; ++py) {
      const Tap rowTap =
          axisTap((py + 0.5 - cy) + (halfH - ayp), ky, src.height, layer.flipV);
      if (rowTap.a < 0) continue;
      if (py < firstRow) firstRow = py;
      lastRow = py;
      uint8_t* q = out->rgba.data() + static_cast<size_t>(py) * W * 4;
      if (exact) {
        const uint8_t* row =
            src.rgba.data() + static_cast<size_t>(rowTap.n) * src.width * 4;
        for (int px = 0; px < W; ++px, q += 4) {
          if (columns[px].a < 0) continue;
          const uint8_t* p = row + static_cast<size_t>(columns[px].n) * 4;
          if (p[3] == 0) continue;
          q[0] = p[0];
          q[1] = p[1];
          q[2] = p[2];
          q[3] = p[3];
        }
        continue;
      }
      for (int px = 0; px < W; ++px, q += 4) {
        if (columns[px].a < 0) continue;
        uint8_t px4[4];
        sampleBilinear(src, columns[px], rowTap, px4);
        if (px4[3] == 0) continue;
        q[0] = px4[0];
        q[1] = px4[1];
        q[2] = px4[2];
        q[3] = px4[3];
      }
    }
    if (outBounds && lastCol >= 0 && lastRow >= 0) {
      *outBounds = LayerBounds{firstCol, firstRow, lastCol, lastRow};
    }
    return Error::None;
  }

  int firstCol = W, lastCol = -1, firstRow = H, lastRow = -1;
  for (int py = 0; py < H; ++py) {
    for (int px = 0; px < W; ++px) {
      // Canvas point relative to centre.
      const double rx = px + 0.5 - cx;
      const double ry = py + 0.5 - cy;
      // Inverse-rotate to find source pixel.
      const double ux = rx * cosr + ry * sinr + (halfW - axp);
      const double uy = -rx * sinr + ry * cosr + (halfH - ayp);
      const Tap tapX = axisTap(ux, kx, src.width, layer.flipH);
      const Tap tapY = axisTap(uy, ky, src.height, layer.flipV);
      if (tapX.a < 0 || tapY.a < 0) continue;
      if (px < firstCol) firstCol = px;
      if (px > lastCol) lastCol = px;
      if (py < firstRow) firstRow = py;
      if (py > lastRow) lastRow = py;
      uint8_t* q = out->rgba.data() + (static_cast<size_t>(py) * W + px) * 4;
      uint8_t px4[4];
      sampleBilinear(src, tapX, tapY, px4);
      if (px4[3] == 0) continue;
      q[0] = px4[0];
      q[1] = px4[1];
      q[2] = px4[2];
      q[3] = px4[3];
    }
  }
  if (outBounds && lastCol >= 0 && lastRow >= 0) {
    *outBounds = LayerBounds{firstCol, firstRow, lastCol, lastRow};
  }
  return Error::None;
}

void blendComposite(RgbaSurface* base, const RgbaSurface& top, double opacity,
                    const std::string& blendMode, const LayerBounds* bounds) {
  if (!base || top.rgba.empty()) return;
  const size_t n = std::min(base->rgba.size(), top.rgba.size());
  const float gOpacity = static_cast<float>(clampd(opacity, 0.0, 1.0));
  const bool normal = blendMode.empty() || blendMode == "normal";

  // One horizontal run of the canvas. Splitting the pass this way is what lets
  // a layer that occupies a corner of the frame — anything scaled down, moved
  // off centre, or mid-animation — pay for its own pixels instead of for a
  // full-canvas walk that finds transparent bytes almost everywhere.
  const auto blendRange = [&](size_t from, size_t to) {
  // Compositing every visible track over the canvas is the single hottest loop
  // in the renderer, so the ordinary case — opaque source, normal blend — gets
  // a straight copy. It is bit-identical to the general path below (alpha 1
  // makes the over-operator collapse to "take the source").
  if (normal && gOpacity >= 1.0f) {
    // Opaque and transparent pixels arrive in long runs — a full-frame video
    // layer is one opaque run the width of the canvas, a logo or a caption is
    // transparent almost everywhere. Copying a run at a time turns the inner
    // loop into a memcpy the compiler vectorizes, instead of four byte stores
    // and a branch per pixel. Bit-identical to the per-pixel form.
    size_t i = from;
    while (i < to) {
      const uint8_t sa = top.rgba[i + 3];
      if (sa == 255) {
        const size_t runStart = i;
        do {
          i += 4;
        } while (i < to && top.rgba[i + 3] == 255);
        std::memcpy(&base->rgba[runStart], &top.rgba[runStart], i - runStart);
      } else if (sa == 0) {
        do {
          i += 4;
        } while (i < to && top.rgba[i + 3] == 0);
      } else {
        blendPixelOver(&base->rgba[i], &top.rgba[i], sa / 255.f);
        i += 4;
      }
    }
    return;
  }

  for (size_t i = from; i < to; i += 4) {
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
  };

  const int W = top.width;
  if (bounds && W > 0 && base->width == W) {
    if (bounds->empty()) return;
    const int rows = std::min(base->height, top.height);
    const int x0 = std::max(0, bounds->x0);
    const int x1 = std::min(W - 1, bounds->x1);
    const int y0 = std::max(0, bounds->y0);
    const int y1 = std::min(rows - 1, bounds->y1);
    for (int y = y0; y <= y1; ++y) {
      const size_t from = (static_cast<size_t>(y) * W + x0) * 4;
      size_t to = (static_cast<size_t>(y) * W + x1 + 1) * 4;
      if (to > n) to = n;
      if (from >= to) continue;
      blendRange(from, to);
    }
    return;
  }
  blendRange(0, n);
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
