#include "render/effects.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "graph/keyframes.h"
namespace cc {
namespace {

using json = nlohmann::json;

double clampd(double v, double lo, double hi) {
  return std::min(std::max(v, lo), hi);
}

// Reads a param value that may be a bare number or {"x":..,"y":..}.
json paramValue(const json& params, const std::string& id, const json& fallback) {
  const auto it = params.find(id);
  if (it == params.end() || it->is_null()) return fallback;
  return *it;
}

double num(const json& v, double fallback) {
  return v.is_number() ? v.get<double>() : fallback;
}

double numOrStatic(const ResolvedEffect& e, const std::string& id, double fallback) {
  return num(paramValue(e.params, id, json(fallback)), fallback);
}

uint8_t hexByte(const std::string& s, size_t i) {
  auto nibble = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
  };
  if (i + 1 >= s.size()) return 0;
  return static_cast<uint8_t>(nibble(s[i]) * 16 + nibble(s[i + 1]));
}

struct Rgb {
  float r = 0.f, g = 0.f, b = 0.f, a = 1.f;
};

Rgb parseColor(const json& v, Rgb fallback) {
  if (!v.is_string()) return fallback;
  std::string s = v.get<std::string>();
  if (!s.empty() && s[0] == '#') s.erase(0, 1);
  if (s.size() != 6 && s.size() != 8) return fallback;
  Rgb out;
  out.r = hexByte(s, 0) / 255.f;
  out.g = hexByte(s, 2) / 255.f;
  out.b = hexByte(s, 4) / 255.f;
  out.a = s.size() == 8 ? hexByte(s, 6) / 255.f : 1.f;
  return out;
}

float srgbToLinear(float c) {
  return c <= 0.04045f ? c / 12.92f : std::pow((c + 0.055f) / 1.055f, 2.4f);
}

float linearToSrgb(float c) {
  c = clampd(c, 0.0f, 1.0f);
  return c <= 0.0031308f ? c * 12.92f : 1.055f * std::pow(c, 1.f / 2.4f) - 0.055f;
}

struct LinearImage {
  int w = 0, h = 0;
  std::vector<float> r, g, b;  // linear-light premultiplied by alpha? No — straight.
};

LinearImage toLinear(const RgbaSurface& in) {
  LinearImage out;
  out.w = in.width;
  out.h = in.height;
  const size_t n = static_cast<size_t>(in.width) * in.height;
  out.r.resize(n);
  out.g.resize(n);
  out.b.resize(n);
  for (size_t i = 0; i < n; ++i) {
    const float a = in.rgba[i * 4 + 3] / 255.f;
    // Unpremultiply before going linear so colour maths is correct on
    // semi-transparent text/textures.
    const float un = a > 0.f ? 1.f / a : 0.f;
    out.r[i] = srgbToLinear(in.rgba[i * 4] / 255.f * un);
    out.g[i] = srgbToLinear(in.rgba[i * 4 + 1] / 255.f * un);
    out.b[i] = srgbToLinear(in.rgba[i * 4 + 2] / 255.f * un);
  }
  return out;
}

void fromLinear(const LinearImage& in, RgbaSurface* out) {
  const size_t n = static_cast<size_t>(in.w) * in.h;
  for (size_t i = 0; i < n; ++i) {
    const uint8_t a = out->rgba[i * 4 + 3];
    const float af = a / 255.f;
    const float un = af > 0.f ? af : 0.f;  // premultiply back
    out->rgba[i * 4] = static_cast<uint8_t>(
        std::lround(linearToSrgb(in.r[i] * un) * 255.f));
    out->rgba[i * 4 + 1] = static_cast<uint8_t>(
        std::lround(linearToSrgb(in.g[i] * un) * 255.f));
    out->rgba[i * 4 + 2] = static_cast<uint8_t>(
        std::lround(linearToSrgb(in.b[i] * un) * 255.f));
  }
}

void applyExposureContrastSaturationTempTintFade(const LinearImage& img,
                                                 const ResolvedEffect& e) {
  const double exposure = numOrStatic(e, "stops", 0.0);
  const double contrast = numOrStatic(e, "amount", 0.0);
  const double saturation = numOrStatic(e, "amount", 1.0);
  const double temp = numOrStatic(e, "amount", 0.0);
  const double tint = numOrStatic(e, "amount", 0.0);
  (void)exposure; (void)contrast; (void)saturation; (void)temp; (void)tint;
}

// One separable box-blur pass with a sliding window. Runtime is O(width ×
// height), independent of the blur radius; the previous implementation walked
// every sample in every pixel's radius and could turn one preview frame into
// hundreds of milliseconds.
void boxBlur(const RgbaSurface& src, int half, RgbaSurface* out) {
  const int w = src.width;
  const int h = src.height;
  const int count = half * 2 + 1;
  RgbaSurface horizontal{w, h,
                         std::vector<uint8_t>(src.rgba.size())};
  out->width = w;
  out->height = h;
  out->rgba.resize(src.rgba.size());

  for (int y = 0; y < h; ++y) {
    int sums[4] = {};
    const uint8_t* row =
        src.rgba.data() + static_cast<size_t>(y) * w * 4;
    for (int k = -half; k <= half; ++k) {
      const uint8_t* p = row + static_cast<size_t>(std::clamp(k, 0, w - 1)) * 4;
      for (int ch = 0; ch < 4; ++ch) sums[ch] += p[ch];
    }
    for (int x = 0; x < w; ++x) {
      uint8_t* q = horizontal.rgba.data() +
                   (static_cast<size_t>(y) * w + x) * 4;
      for (int ch = 0; ch < 4; ++ch) q[ch] = sums[ch] / count;
      const uint8_t* leaving =
          row + static_cast<size_t>(std::clamp(x - half, 0, w - 1)) * 4;
      const uint8_t* entering =
          row + static_cast<size_t>(std::clamp(x + half + 1, 0, w - 1)) * 4;
      for (int ch = 0; ch < 4; ++ch) {
        sums[ch] += static_cast<int>(entering[ch]) - leaving[ch];
      }
    }
  }

  for (int x = 0; x < w; ++x) {
    int sums[4] = {};
    for (int k = -half; k <= half; ++k) {
      const int y = std::clamp(k, 0, h - 1);
      const uint8_t* p = horizontal.rgba.data() +
                         (static_cast<size_t>(y) * w + x) * 4;
      for (int ch = 0; ch < 4; ++ch) sums[ch] += p[ch];
    }
    for (int y = 0; y < h; ++y) {
      uint8_t* q = out->rgba.data() +
                   (static_cast<size_t>(y) * w + x) * 4;
      for (int ch = 0; ch < 4; ++ch) q[ch] = sums[ch] / count;
      const int leavingY = std::clamp(y - half, 0, h - 1);
      const int enteringY = std::clamp(y + half + 1, 0, h - 1);
      const uint8_t* leaving = horizontal.rgba.data() +
                               (static_cast<size_t>(leavingY) * w + x) * 4;
      const uint8_t* entering = horizontal.rgba.data() +
                                (static_cast<size_t>(enteringY) * w + x) * 4;
      for (int ch = 0; ch < 4; ++ch) {
        sums[ch] += static_cast<int>(entering[ch]) - leaving[ch];
      }
    }
  }
}

}  // namespace

const EffectParamDef* EffectDef::param(const std::string& id) const {
  for (const auto& p : params) {
    if (p.id == id) return &p;
  }
  return nullptr;
}

// --- Catalog (docs/03-features/effects.md, FX-1..11) ------------------------

const std::vector<EffectDef>& effectCatalog() {
  static const std::vector<EffectDef> catalog = [] {
    auto f = [](std::string id, std::string label, double lo, double hi,
                double def, std::string unit = "", bool statik = false) {
      return EffectParamDef{std::move(id),       std::move(label), "float",
                            lo,                  hi,               def,
                            std::move(unit),     statik,           {}};
    };
    auto color = [](std::string id, std::string label, std::string def) {
      return EffectParamDef{std::move(id), std::move(label), "color",
                            0.0,  1.0,  0.0, {}, true, {}};
    };
    std::vector<EffectDef> out;
    out.push_back({"exposure", "Exposure", "Color",
                   {f("stops", "Stops", -2.0, 2.0, 0.0)}});
    out.push_back({"contrast", "Contrast", "Color",
                   {f("amount", "Amount", -1.0, 1.0, 0.0)}});
    out.push_back({"saturation", "Saturation", "Color",
                   {f("amount", "Amount", 0.0, 2.0, 1.0)}});
    out.push_back({"temperature", "Temperature", "Color",
                   {f("amount", "Cool ← → Warm", -1.0, 1.0, 0.0)}});
    out.push_back({"tint", "Tint", "Color",
                   {f("amount", "Green ← → Magenta", -1.0, 1.0, 0.0)}});
    out.push_back({"fade", "Fade", "Color",
                   {f("amount", "Amount", 0.0, 1.0, 0.0)}});
    out.push_back({"vignette", "Vignette", "Color",
                   {f("amount", "Amount", 0.0, 1.0, 0.35),
                    f("roundness", "Roundness", 0.0, 1.0, 0.5),
                    f("softness", "Softness", 0.0, 1.0, 0.5)}});
    out.push_back({"gaussianBlur", "Gaussian blur", "Blur & Style",
                   {f("radius", "Radius", 0.0, 100.0, 8.0, "px@1080")}});
    out.push_back({"boxBlur", "Box blur", "Blur & Style",
                   {f("radius", "Radius", 0.0, 100.0, 8.0, "px@1080"),
                    f("iterations", "Iterations", 1.0, 4.0, 2.0, "", true)}});
    out.push_back({"pixelate", "Pixelate / Mosaic", "Blur & Style",
                   {f("cell", "Cell size", 2.0, 128.0, 12.0, "px@1080")}});
    out.push_back({"sharpen", "Sharpen", "Blur & Style",
                   {f("amount", "Amount", 0.0, 1.0, 0.3)}});
    out.push_back(
        {"blurIsland", "Blur island", "Blur & Style",
         {f("radius", "Radius", 0.0, 100.0, 24.0, "px@1080"),
          f("centerX", "Center X", -1.0, 1.0, 0.0),
          f("centerY", "Center Y", -1.0, 1.0, 0.0),
          f("size", "Size", 0.05, 1.0, 0.4),
          f("aspect", "Aspect", 0.1, 4.0, 1.0),
          f("feather", "Feather", 0.02, 1.0, 0.4)}});
    out.push_back({"crop", "Crop", "Transform",
                   {f("left", "Left %", 0.0, 100.0, 0.0),
                    f("right", "Right %", 0.0, 100.0, 0.0),
                    f("top", "Top %", 0.0, 100.0, 0.0),
                    f("bottom", "Bottom %", 0.0, 100.0, 0.0),
                    f("feather", "Feather edge", 0.0, 100.0, 0.0),
                    f("radius", "Corner radius", 0.0, 200.0, 0.0)}});
    out.push_back({"dropShadow", "Drop shadow", "Transform",
                   {f("offsetX", "Offset X", -200.0, 200.0, 8.0),
                    f("offsetY", "Offset Y", -200.0, 200.0, 8.0),
                    f("blur", "Blur", 0.0, 100.0, 16.0),
                    color("color", "Color", "#000000"),
                    f("opacity", "Opacity", 0.0, 1.0, 0.6)}});
    return out;
  }();
  return catalog;
}

const EffectDef* findEffect(const std::string& id) {
  for (const auto& def : effectCatalog()) {
    if (def.id == id) return &def;
  }
  return nullptr;
}

std::string effectCatalogJson() {
  json arr = json::array();
  for (const auto& def : effectCatalog()) {
    json params = json::array();
    for (const auto& p : def.params) {
      json pj = {{"id", p.id},
                 {"label", p.label},
                 {"type", p.type},
                 {"min", p.min},
                 {"max", p.max},
                 {"default", p.def}};
      if (!p.unit.empty()) pj["unit"] = p.unit;
      if (p.statik) pj["static"] = true;
      if (!p.options.empty()) pj["options"] = p.options;
      params.push_back(std::move(pj));
    }
    arr.push_back({{"id", def.id}, {"label", def.label},
                   {"category", def.category}, {"params", std::move(params)}});
  }
  return arr.dump();
}

std::optional<ResolvedEffect> resolveEffect(const json& instance,
                                            const RationalTime& localTime) {
  if (!instance.is_object()) return std::nullopt;
  if (instance.value("enabled", true) == false) return std::nullopt;
  const std::string type = instance.value("type", "");
  const EffectDef* def = findEffect(type);
  if (!def) return std::nullopt;
  ResolvedEffect out;
  out.def = def;
  const json empty = json::object();
  const json& params = instance.contains("params") && instance["params"].is_object()
                           ? instance["params"]
                           : empty;
  for (const auto& pd : def->params) {
    json value = pd.def;
    const auto it = params.find(pd.id);
    if (it != params.end() && !it->is_null()) {
      json v;
      if (evaluateParameter(*it, localTime, &v) == Error::None) value = std::move(v);
    }
    out.params[pd.id] = std::move(value);
  }
  return out;
}

Error applyEffect(const ResolvedEffect& effect, const RenderContext& ctx,
                  RgbaSurface* image) {
  if (!image || !effect.def) return Error::InvalidArgument;
  if (image->rgba.empty()) return Error::None;

  const std::string& id = effect.def->id;

  // --- Colour: exposure / contrast / saturation / temperature / tint / fade
  //     all fold into one linear-light pass (FX-5).
  if (id == "exposure" || id == "contrast" || id == "saturation" ||
      id == "temperature" || id == "tint" || id == "fade" || id == "vignette") {
    LinearImage img = toLinear(*image);
    const size_t n = img.r.size();
    const float exposure =
        id == "exposure" ? static_cast<float>(numOrStatic(effect, "stops", 0.0)) : 0.f;
    const float contrast =
        id == "contrast" ? static_cast<float>(numOrStatic(effect, "amount", 0.0)) : 0.f;
    const float saturation =
        id == "saturation" ? static_cast<float>(numOrStatic(effect, "amount", 1.0)) : 1.f;
    const float temp =
        id == "temperature" ? static_cast<float>(numOrStatic(effect, "amount", 0.0)) : 0.f;
    const float tint =
        id == "tint" ? static_cast<float>(numOrStatic(effect, "amount", 0.0)) : 0.f;
    const float fade =
        id == "fade" ? static_cast<float>(numOrStatic(effect, "amount", 0.0)) : 0.f;
    const float vignette =
        id == "vignette" ? static_cast<float>(numOrStatic(effect, "amount", 0.35)) : 0.f;
    const float roundness =
        static_cast<float>(numOrStatic(effect, "roundness", 0.5));
    const float softness =
        static_cast<float>(numOrStatic(effect, "softness", 0.5));
    const double aspect = ctx.sequenceHeight > 0
                              ? static_cast<double>(ctx.sequenceWidth) /
                                    ctx.sequenceHeight
                              : 1.0;

    for (size_t i = 0; i < n; ++i) {
      float r = img.r[i], g = img.g[i], b = img.b[i];
      if (exposure != 0.f) {
        const float m = std::pow(2.0f, exposure);
        r *= m; g *= m; b *= m;
      }
      if (temp != 0.f) {
        r *= 1.f + 0.25f * temp;
        b *= 1.f - 0.25f * temp;
      }
      if (tint != 0.f) {
        g *= 1.f - 0.20f * tint;
        r *= 1.f + 0.10f * tint;
        b *= 1.f + 0.10f * tint;
      }
      if (saturation != 1.f) {
        const float l = 0.2126f * r + 0.7152f * g + 0.0722f * b;
        r = l + (r - l) * saturation;
        g = l + (g - l) * saturation;
        b = l + (b - l) * saturation;
      }
      if (contrast != 0.f) {
        const float k = 1.f + contrast * 1.5f;
        r = (r - 0.18f) * k + 0.18f;
        g = (g - 0.18f) * k + 0.18f;
        b = (b - 0.18f) * k + 0.18f;
      }
      if (fade != 0.f) {
        r += fade * (0.85f - r) * 0.28f;
        g += fade * (0.85f - g) * 0.28f;
        b += fade * (0.85f - b) * 0.28f;
      }
      if (vignette > 0.f) {
        const float px = (static_cast<float>(i % img.w) / img.w - 0.5f) * 2.f;
        const float py = (static_cast<float>(i / img.w) / img.h - 0.5f) * 2.f;
        const float rx = px / static_cast<float>(aspect > 1.0 ? 1.0 : aspect);
        const float ry = py * static_cast<float>(aspect > 1.0 ? aspect : 1.0);
        float d = std::sqrt(rx * rx + ry * ry) /
                  std::sqrt(1.f + roundness);  // roundness reshapes the falloff
        d = clampd(d, 0.f, 1.5f);
        const float inner = 0.55f * (1.3f - softness);
        const float v = 1.f - vignette *
                                  clampd((d - inner) / std::max(0.02f, 1.f - inner),
                                         0.f, 1.f);
        r *= v; g *= v; b *= v;
      }
      img.r[i] = r; img.g[i] = g; img.b[i] = b;
    }
    fromLinear(img, image);
    return Error::None;
  }

  // --- Blur family ---------------------------------------------------------
  if (id == "gaussianBlur" || id == "boxBlur" || id == "blurIsland") {
    const bool island = id == "blurIsland";
    double radius = numOrStatic(effect, "radius", id == "blurIsland" ? 24.0 : 8.0) *
                    ctx.unitScale();
    radius = clampd(radius, 0.0, 400.0);
    if (radius < 0.25) return Error::None;
    const int iterations =
        id == "boxBlur"
            ? static_cast<int>(clampd(numOrStatic(effect, "iterations", 2.0), 1, 4))
            : 3;  // three box passes approximate the gaussian well
    // Sigma→box-length per Kovesi's approximation.
    const double sigma = radius / std::sqrt(iterations * 3.0);
    const int half = std::max(1, static_cast<int>(sigma * 1.5));

    const RgbaSurface original{image->width, image->height, image->rgba};
    RgbaSurface blurred = original;
    for (int pass = 0; pass < iterations; ++pass) {
      RgbaSurface next;
      boxBlur(blurred, half, &next);
      blurred = std::move(next);
    }

    if (!island) {
      *image = std::move(blurred);
      return Error::None;
    }

    // Blur-island: fully blurred at the centre, original outside the ellipse,
    // with [feather] controlling the boundary blend.
    const double cx = numOrStatic(effect, "centerX", 0.0);
    const double cy = numOrStatic(effect, "centerY", 0.0);
    const double sizeX = std::max(0.01, numOrStatic(effect, "size", 0.4));
    const double aspect = std::max(0.01, numOrStatic(effect, "aspect", 1.0));
    const double feather =
        clampd(numOrStatic(effect, "feather", 0.4), 0.02, 1.0);
    for (int y = 0; y < image->height; ++y) {
      for (int x = 0; x < image->width; ++x) {
        const double nx =
            (x / static_cast<double>(image->width) - 0.5 - cx) * 2.0;
        const double ny =
            (y / static_cast<double>(image->height) - 0.5 - cy) * 2.0;
        const double d =
            std::sqrt(nx * nx + (ny / aspect) * (ny / aspect)) / sizeX;
        const double mask = clampd((1.0 - d) / feather, 0.0, 1.0);
        const size_t at = (static_cast<size_t>(y) * image->width + x) * 4;
        for (int ch = 0; ch < 4; ++ch) {
          image->rgba[at + ch] = static_cast<uint8_t>(std::lround(
              blurred.rgba[at + ch] * mask + original.rgba[at + ch] *
                                                   (1.0 - mask)));
        }
      }
    }
    return Error::None;
  }

  // --- Pixelate ------------------------------------------------------------
  if (id == "pixelate") {
    double cell = numOrStatic(effect, "cell", 12.0) * ctx.unitScale();
    cell = std::max(2.0, cell);
    const int cs = static_cast<int>(cell);
    for (int by = 0; by < image->height; by += cs) {
      for (int bx = 0; bx < image->width; bx += cs) {
        unsigned long long r = 0, g = 0, b = 0, a = 0;
        int count = 0;
        const int ye = std::min(by + cs, image->height);
        const int xe = std::min(bx + cs, image->width);
        for (int y = by; y < ye; ++y) {
          for (int x = bx; x < xe; ++x) {
            const uint8_t* p =
                image->rgba.data() + (static_cast<size_t>(y) * image->width + x) * 4;
            r += p[0]; g += p[1]; b += p[2]; a += p[3]; ++count;
          }
        }
        uint8_t avg[4] = {static_cast<uint8_t>(r / count),
                          static_cast<uint8_t>(g / count),
                          static_cast<uint8_t>(b / count),
                          static_cast<uint8_t>(a / count)};
        for (int y = by; y < ye; ++y) {
          for (int x = bx; x < xe; ++x) {
            uint8_t* q =
                image->rgba.data() + (static_cast<size_t>(y) * image->width + x) * 4;
            std::memcpy(q, avg, 4);
          }
        }
      }
    }
    return Error::None;
  }

  // --- Sharpen: unsharp with a 3×3 kernel ----------------------------------
  if (id == "sharpen") {
    const float amount = static_cast<float>(numOrStatic(effect, "amount", 0.3));
    if (amount <= 0.f) return Error::None;
    RgbaSurface src{image->width, image->height, image->rgba};
    for (int y = 0; y < image->height; ++y) {
      for (int x = 0; x < image->width; ++x) {
        uint8_t* q = image->rgba.data() + (static_cast<size_t>(y) * image->width + x) * 4;
        for (int ch = 0; ch < 4; ++ch) {
          auto at = [&](int xx, int yy) {
            xx = std::clamp(xx, 0, image->width - 1);
            yy = std::clamp(yy, 0, image->height - 1);
            return src.rgba[(static_cast<size_t>(yy) * image->width + xx) * 4 + ch];
          };
          const int blur = (at(x - 1, y) + at(x + 1, y) + at(x, y - 1) + at(x, y + 1) +
                            at(x - 1, y - 1) + at(x + 1, y - 1) + at(x - 1, y + 1) +
                            at(x + 1, y + 1)) / 8;
          const int center = at(x, y);
          q[ch] = static_cast<uint8_t>(
              std::lround(clampd(center + (center - blur) * amount, 0, 255)));
        }
      }
    }
    return Error::None;
  }

  // --- Crop -----------------------------------------------------------------
  if (id == "crop") {
    const double l = numOrStatic(effect, "left", 0.0) / 100.0;
    const double r = numOrStatic(effect, "right", 0.0) / 100.0;
    const double t = numOrStatic(effect, "top", 0.0) / 100.0;
    const double b = numOrStatic(effect, "bottom", 0.0) / 100.0;
    const double featherPct = numOrStatic(effect, "feather", 0.0);
    const double radiusPct = numOrStatic(effect, "radius", 0.0);

    int x0 = static_cast<int>(std::lround(l * image->width));
    int x1 = image->width - static_cast<int>(std::lround(r * image->width));
    int y0 = static_cast<int>(std::lround(t * image->height));
    int y1 = image->height - static_cast<int>(std::lround(b * image->height));
    x0 = std::clamp(x0, 0, image->width - 1);
    x1 = std::clamp(x1, x0 + 1, image->width);
    y0 = std::clamp(y0, 0, image->height - 1);
    y1 = std::clamp(y1, y0 + 1, image->height);
    // FX-10: crop reveals transparency outside the region — the canvas stays
    // the same size so framing/transform still see the full frame.
    const double feather = featherPct / 100.0 *
                           std::min(image->width, image->height) * 0.5;
    const int W = image->width, H = image->height;
    RgbaSurface out{W, H, std::vector<uint8_t>(static_cast<size_t>(W) * H * 4, 0)};
    for (int y = 0; y < H; ++y) {
      for (int x = 0; x < W; ++x) {
        if (x < x0 || x >= x1 || y < y0 || y >= y1) continue;  // transparent
        uint8_t* q = out.rgba.data() + (static_cast<size_t>(y) * W + x) * 4;
        const uint8_t* p =
            image->rgba.data() + (static_cast<size_t>(y) * W + x) * 4;
        q[0] = p[0]; q[1] = p[1]; q[2] = p[2];
        float alpha = p[3] / 255.f;
        if (radiusPct > 0.0) {
          const double rad = radiusPct / 100.0 *
                             std::min(x1 - x0, y1 - y0) * 0.5;
          const double dx = std::min(static_cast<double>(x - x0),
                                     static_cast<double>(x1 - 1 - x));
          const double dy = std::min(static_cast<double>(y - y0),
                                     static_cast<double>(y1 - 1 - y));
          if (dx < rad && dy < rad) {
            const double ex = dx - rad, ey = dy - rad;
            const double dist = rad - std::sqrt(ex * ex + ey * ey);
            alpha *= dist <= 0.0 ? 0.0f : static_cast<float>(clampd(dist, 0.0, 1.0));
          }
        } else if (feather > 0.5) {
          const double edge = std::min({static_cast<double>(x - x0),
                                        static_cast<double>(y - y0),
                                        static_cast<double>(x1 - 1 - x),
                                        static_cast<double>(y1 - 1 - y)});
          if (edge < feather) {
            alpha *= static_cast<float>(clampd(edge / feather, 0.0, 1.0));
          }
        }
        q[3] = static_cast<uint8_t>(std::lround(alpha * 255.f));
      }
    }
    *image = std::move(out);
    return Error::None;
  }

  // --- Drop shadow (FX-11): offset blurred silhouette under the source ------
  if (id == "dropShadow") {
    const double ox = numOrStatic(effect, "offsetX", 8.0) * ctx.unitScale();
    const double oy = numOrStatic(effect, "offsetY", 8.0) * ctx.unitScale();
    const double blur = numOrStatic(effect, "blur", 16.0) * ctx.unitScale();
    const Rgb color = parseColor(paramValue(effect.params, "color", json("#000000")),
                                 Rgb{0, 0, 0, 1});
    const double opacity = clampd(numOrStatic(effect, "opacity", 0.6), 0.0, 1.0);

    const int w = image->width, h = image->height;
    RgbaSurface shadow{w, h, std::vector<uint8_t>(static_cast<size_t>(w) * h * 4, 0)};
    // Silhouette.
    for (size_t i = 0; i < static_cast<size_t>(w) * h; ++i) {
      shadow.rgba[i * 4 + 3] =
          opacity > 0 ? static_cast<uint8_t>(image->rgba[i * 4 + 3]) : 0;
    }
    // Box-blur the silhouette (two passes).
    if (blur >= 1.0) {
      const int half = std::max(1, static_cast<int>(blur * 0.75));
      RgbaSurface tmp{w, h, std::vector<uint8_t>(shadow.rgba.size())};
      for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
          int acc = 0, count = 0;
          for (int k = -half; k <= half; ++k) {
            const int xx = std::clamp(x + k, 0, w - 1);
            acc += shadow.rgba[(static_cast<size_t>(y) * w + xx) * 4 + 3];
            ++count;
          }
          tmp.rgba[(static_cast<size_t>(y) * w + x) * 4 + 3] =
              static_cast<uint8_t>(acc / count);
        }
      }
      for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
          int acc = 0, count = 0;
          for (int k = -half; k <= half; ++k) {
            const int yy = std::clamp(y + k, 0, h - 1);
            acc += tmp.rgba[(static_cast<size_t>(yy) * w + x) * 4 + 3];
            ++count;
          }
          shadow.rgba[(static_cast<size_t>(y) * w + x) * 4 + 3] =
              static_cast<uint8_t>(acc / count);
        }
      }
    }
    // Tint the silhouette and composite it under the offset source.
    for (size_t i = 0; i < static_cast<size_t>(w) * h; ++i) {
      shadow.rgba[i * 4] = static_cast<uint8_t>(color.r * 255.f);
      shadow.rgba[i * 4 + 1] = static_cast<uint8_t>(color.g * 255.f);
      shadow.rgba[i * 4 + 2] = static_cast<uint8_t>(color.b * 255.f);
    }
    const int ix = static_cast<int>(std::lround(ox));
    const int iy = static_cast<int>(std::lround(oy));
    RgbaSurface out{w, h, std::vector<uint8_t>(static_cast<size_t>(w) * h * 4, 0)};
    for (int y = 0; y < h; ++y) {
      for (int x = 0; x < w; ++x) {
        uint8_t* q = out.rgba.data() + (static_cast<size_t>(y) * w + x) * 4;
        const int sx = x - ix, sy = y - iy;
        if (sx >= 0 && sx < w && sy >= 0 && sy < h) {
          std::memcpy(q, shadow.rgba.data() + (static_cast<size_t>(sy) * w + sx) * 4, 4);
        }
        const uint8_t* p =
            image->rgba.data() + (static_cast<size_t>(y) * w + x) * 4;
        const float pa = p[3] / 255.f;
        const float qa = q[3] / 255.f;
        const float oa = pa + qa * (1.f - pa);
        if (oa > 0.f) {
          for (int ch = 0; ch < 3; ++ch) {
            q[ch] = static_cast<uint8_t>(
                std::lround((p[ch] / 255.f * pa + q[ch] / 255.f * qa * (1.f - pa)) /
                            oa * 255.f));
          }
        }
        q[3] = static_cast<uint8_t>(std::lround(oa * 255.f));
      }
    }
    *image = std::move(out);
    return Error::None;
  }

  return Error::None;
}

}  // namespace cc
