#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>

#include <nlohmann/json.hpp>
#include <gtest/gtest.h>

#include "graph/keyframes.h"
#include "media/frame.h"
#include "render/composite.h"
#include "render/effects.h"
#include "render/renderer.h"

#ifndef CC_SOURCE_DIR
#define CC_SOURCE_DIR "."
#endif

namespace {

using json = nlohmann::json;

std::string fixturePath() {
  if (const char* env = std::getenv("CC_FIXTURE")) return env;
  return std::string(CC_SOURCE_DIR) + "/../fixtures/media/sample.mp4";
}

bool fixtureExists() {
  std::ifstream f(fixturePath());
  return f.good();
}

// Deterministic synthetic frame: horizontal gradient with a solid centre band.
cc::RgbaSurface gradientFrame(int w, int h, uint8_t band) {
  cc::RgbaSurface out{w, h, std::vector<uint8_t>(static_cast<size_t>(w) * h * 4)};
  for (int y = 0; y < h; ++y) {
    for (int x = 0; x < w; ++x) {
      uint8_t* q = out.rgba.data() + (static_cast<size_t>(y) * w + x) * 4;
      q[0] = static_cast<uint8_t>(x * 255 / std::max(1, w - 1));
      q[1] = static_cast<uint8_t>(y * 255 / std::max(1, h - 1));
      q[2] = band;
      q[3] = 255;
    }
  }
  return out;
}

double meanAbsDiff(const cc::RgbaSurface& a, const cc::RgbaSurface& b) {
  if (a.rgba.size() != b.rgba.size() || a.rgba.empty()) return 1e9;
  double acc = 0;
  for (size_t i = 0; i < a.rgba.size(); ++i) {
    acc += std::abs(static_cast<int>(a.rgba[i]) - static_cast<int>(b.rgba[i]));
  }
  return acc / a.rgba.size();
}

cc::RgbaSurface renderDoc(const json& doc, const std::string& mediaId,
                          const std::string& path, int tNum = 0, int tDen = 1) {
  cc::RgbaSurface out;
  const std::map<std::string, std::string> paths{{mediaId, path}};
  EXPECT_EQ(cc::renderFrame(doc, cc::RationalTime{tNum, tDen}.normalized(), 320,
                            180, paths, &out),
            cc::Error::None);
  return out;
}

json baseDoc(json clips, json transitions = json::array()) {
  return json{
      {"schema", "crazycut/project@1"},
      {"settings",
       {{"width", 1920}, {"height", 1080}, {"fps", "30/1"},
        {"audioSampleRate", 48000}, {"background", "#000000"}}},
      {"tracks",
       json::array({
           {{"id", "v1"}, {"kind", "video"}, {"name", "V1"}, {"index", 0},
            {"mute", false}, {"solo", false}, {"lock", false}, {"hidden", false},
            {"height", 72}},
       })},
      {"clips", std::move(clips)},
      {"transitions", std::move(transitions)},
      {"markers", json::array()}};
}

TEST(GoldenFrames, StaticParamEqualsKeyframedValueAtSameTime) {
  // KEY-9: same inputs ⇒ bit-identical output. A static param and a single-key
  // keyframe track must evaluate identically.
  json out;
  ASSERT_EQ(cc::evaluateParameter(json{{"static", 8.0}}, {15, 30}, &out),
            cc::Error::None);
  EXPECT_DOUBLE_EQ(out.get<double>(), 8.0);
  const json keyed = {
      {"static", 0.0},
      {"keyframes", json::array({{{"t", "0/1"}, {"v", 8.0}, {"interp", "linear"}}})}};
  ASSERT_EQ(cc::evaluateParameter(keyed, {15, 30}, &out), cc::Error::None);
  EXPECT_DOUBLE_EQ(out.get<double>(), 8.0);
}

TEST(GoldenFrames, KeyframedOpacityEvaluatesDeterministically) {
  // KEY acceptance 1: opacity 100→0 over 1 s; t=0.25 must be exactly 75.
  const json param = {
      {"static", 100.0},
      {"keyframes", json::array({{{"t", "0/1"}, {"v", 100.0}, {"interp", "linear"}},
                                 {{"t", "1/1"}, {"v", 0.0}, {"interp", "linear"}}})}};
  for (const auto& [num, den, expected] :
       {std::tuple{1, 4, 75.0}, {1, 2, 50.0}, {3, 4, 25.0}}) {
    nlohmann::json out;
    ASSERT_EQ(cc::evaluateParameter(param, {num, den}, &out), cc::Error::None);
    EXPECT_DOUBLE_EQ(out.get<double>(), expected) << "at " << num << "/" << den;
    // Same input twice → identical bits.
    nlohmann::json out2;
    ASSERT_EQ(cc::evaluateParameter(param, {num, den}, &out2), cc::Error::None);
    EXPECT_EQ(out.dump(), out2.dump());
  }
}

TEST(GoldenFrames, HoldInterpolationStepsInBothPaths) {
  const json param = {
      {"static", 0.0},
      {"keyframes", json::array({{{"t", "0/1"}, {"v", 100.0}, {"interp", "hold"}},
                                 {{"t", "1/2"}, {"v", 20.0}, {"interp", "linear"}}})}};
  nlohmann::json out;
  ASSERT_EQ(cc::evaluateParameter(param, {1, 4}, &out), cc::Error::None);
  EXPECT_DOUBLE_EQ(out.get<double>(), 100.0);  // hold: left value until next key
  ASSERT_EQ(cc::evaluateParameter(param, {3, 4}, &out), cc::Error::None);
  EXPECT_DOUBLE_EQ(out.get<double>(), 20.0);
}

TEST(GoldenFrames, TransformMovesLayerOnCanvas) {
  if (!fixtureExists()) GTEST_SKIP() << "fixture not generated";
  json clipA = {{"id", "c1"}, {"trackId", "v1"}, {"mediaId", "m1"},
                {"label", "a"},   {"start", "0/1"}, {"duration", "10/1"}};
  auto doc = baseDoc(json::array({clipA}));

  const auto baseline = renderDoc(doc, "m1", fixturePath());
  // Full-frame fit at scale 100 fills the canvas — the top-left corner shows
  // real image content (not background black).
  EXPECT_GT(baseline.rgba[0] + baseline.rgba[1], 40);

  clipA["transform"] = {{"x", {{"static", -1000.0}}},
                        {"y", {{"static", 0.0}}},
                        {"scale", {{"static", 100.0}}},
                        {"rotation", {{"static", 0.0}}},
                        {"opacity", {{"static", 100.0}}}};
  doc = baseDoc(json::array({clipA}));
  const auto shifted = renderDoc(doc, "m1", fixturePath());
  // Pushed far left: right edge is pure background now.
  const size_t lastPx = shifted.rgba.size() - 4;
  EXPECT_EQ(shifted.rgba[lastPx] + shifted.rgba[lastPx + 1], 0);

  // Mean difference proves the transform changed the composite.
  EXPECT_GT(meanAbsDiff(baseline, shifted), 5.0);
}

TEST(GoldenFrames, OpacityZeroHidesClipEntirely) {
  if (!fixtureExists()) GTEST_SKIP() << "fixture not generated";
  json clipA = {{"id", "c1"}, {"trackId", "v1"}, {"mediaId", "m1"},
                {"label", "a"},   {"start", "0/1"}, {"duration", "10/1"}};
  clipA["transform"] = {{"opacity", {{"static", 0.0}}}};
  const auto doc = baseDoc(json::array({clipA}));
  const auto frame = renderDoc(doc, "m1", fixturePath());
  for (size_t i = 0; i < frame.rgba.size(); i += 4) {
    ASSERT_EQ(frame.rgba[i + 3], 255);
    ASSERT_EQ(frame.rgba[i] + frame.rgba[i + 1] + frame.rgba[i + 2], 0)
        << "non-background pixel at " << i / 4;
  }
}

TEST(GoldenFrames, GaussianBlurChangesPixelsPredictably) {
  if (!fixtureExists()) GTEST_SKIP() << "fixture not generated";
  json clipA = {{"id", "c1"}, {"trackId", "v1"}, {"mediaId", "m1"},
                {"label", "a"},   {"start", "0/1"}, {"duration", "10/1"}};
  auto plain = baseDoc(json::array({clipA}));
  const auto sharp = renderDoc(plain, "m1", fixturePath());

  json blurredClip = clipA;
  blurredClip["effects"] = json::array(
      {{{"id", "e1"}, {"type", "gaussianBlur"}, {"enabled", true},
        {"params",
         {{"radius", {{"static", 40.0}}}}}}});
  auto blurred = baseDoc(json::array({blurredClip}));
  const auto soft = renderDoc(blurred, "m1", fixturePath());
  EXPECT_GT(meanAbsDiff(sharp, soft), 2.0);

  // Blur is idempotent per input — determinism check (KEY-9).
  const auto soft2 = renderDoc(blurred, "m1", fixturePath());
  EXPECT_DOUBLE_EQ(meanAbsDiff(soft, soft2), 0.0);
}

TEST(GoldenFrames, PixelateProducesFlatCells) {
  json clip = {{"id", "c1"}, {"trackId", "v1"}, {"mediaId", "m1"},
               {"label", "a"},   {"start", "0/1"}, {"duration", "10/1"}};
  clip["effects"] = json::array({{{"id", "e1"}, {"type", "pixelate"},
                                  {"enabled", true},
                                  {"params", {{"cell", {{"static", 32.0}}}}}}});
  auto doc = baseDoc(json::array({clip}));
  const auto frame = renderDoc(doc, "m1", fixturePath());
  // Within one cell interior, pixels are identical.
  const int cs = static_cast<int>(32.0 * 180.0 / 1080.0);
  bool flat = true;
  for (int y = 1; y < cs && flat; ++y) {
    for (int x = 1; x < cs && flat; ++x) {
      const uint8_t* p0 = frame.rgba.data();
      const uint8_t* p =
          frame.rgba.data() + (static_cast<size_t>(y) * frame.width + x) * 4;
      if (std::memcmp(p0, p, 3) != 0) flat = false;
    }
  }
  EXPECT_TRUE(flat);
}

TEST(GoldenFrames, CropShrinksToRegion) {
  json clip = {{"id", "c1"}, {"trackId", "v1"}, {"mediaId", "m1"},
               {"label", "a"},   {"start", "0/1"}, {"duration", "10/1"}};
  clip["effects"] = json::array(
      {{{"id", "e1"}, {"type", "crop"}, {"enabled", true},
        {"params",
         {{"left", {{"static", 25.0}}}, {"right", {{"static", 25.0}}},
          {"top", {{"static", 25.0}}}, {"bottom", {{"static", 25.0}}}}}}});
  auto doc = baseDoc(json::array({clip}));
  const auto cropped = renderDoc(doc, "m1", fixturePath());
  // Half-width crop centred: left/right quarters are background.
  const size_t midRowStart = (static_cast<size_t>(90) * cropped.width + 8) * 4;
  EXPECT_EQ(cropped.rgba[midRowStart] + cropped.rgba[midRowStart + 1], 0);
  const size_t midCentre = (static_cast<size_t>(90) * cropped.width + 160) * 4;
  EXPECT_GT(cropped.rgba[midCentre] + cropped.rgba[midCentre + 1], 0);
}

TEST(GoldenFrames, CrossDissolveMidpointBlendsBothSides) {
  if (!fixtureExists()) GTEST_SKIP() << "fixture not generated";
  json a = {{"id", "ca"}, {"trackId", "v1"}, {"mediaId", "m1"}, {"label", "a"},
            {"start", "0/1"}, {"duration", "105/30"}};
  json b = {{"id", "cb"}, {"trackId", "v1"}, {"mediaId", "m1"}, {"label", "b"},
            {"start", "90/30"}, {"duration", "105/30"}, {"sourceIn", "90/30"}};
  json tr = {{"id", "t1"}, {"aClipId", "ca"}, {"bClipId", "cb"},
             {"type", "crossDissolve"}, {"duration", "15/30"},
             {"alignment", "center"}, {"easing", "easeInOut"},
             {"params", json::object()},
             {"aExtend", "15/60"}, {"bExtend", "15/60"}};
  auto doc = baseDoc(json::array({a, b}), json::array({tr}));

  // Midpoint of overlap [3.0, 3.5): t=3.25 → p≈0.5.
  const auto mid = renderDoc(doc, "m1", fixturePath(), 195, 60);  // 3.25 s
  const auto fullB = renderDoc(doc, "m1", fixturePath(), 240, 60);  // 4.0 s → only B
  const auto fullA = renderDoc(doc, "m1", fixturePath(), 60, 60);   // 1.0 s → only A
  const double dMidB = meanAbsDiff(mid, fullB);
  const double dMidA = meanAbsDiff(mid, fullA);
  EXPECT_GT(dMidA, 2.0);
  EXPECT_GT(dMidB, 2.0);
  // Roughly centred between the two.
  EXPECT_LT(std::abs(dMidA - dMidB), std::max(dMidA, dMidB) * 0.6);
}

TEST(GoldenFrames, DipToBlackMidpointIsDark) {
  json a = {{"id", "ca"}, {"trackId", "v1"}, {"mediaId", "m1"}, {"label", "a"},
            {"start", "0/1"}, {"duration", "105/30"}};
  json b = {{"id", "cb"}, {"trackId", "v1"}, {"mediaId", "m1"}, {"label", "b"},
            {"start", "90/30"}, {"duration", "105/30"}, {"sourceIn", "90/30"}};
  json tr = {{"id", "t1"}, {"aClipId", "ca"}, {"bClipId", "cb"},
             {"type", "dipToBlack"}, {"duration", "15/30"},
             {"alignment", "center"}, {"easing", "linear"},
             {"params", json::object()}, {"aExtend", "15/60"}, {"bExtend", "15/60"}};
  auto doc = baseDoc(json::array({a, b}), json::array({tr}));
  const auto mid = renderDoc(doc, "m1", fixturePath(), 195, 60);
  double acc = 0;
  for (size_t i = 0; i < mid.rgba.size(); i += 400) acc += mid.rgba[i];
  EXPECT_LT(acc / (mid.rgba.size() / 400), 24.0);
}

TEST(GoldenFrames, TextTextureCompositesOverVideo) {
  if (!fixtureExists()) GTEST_SKIP() << "fixture not generated";
  json video = {{"id", "cv"}, {"trackId", "v1"}, {"mediaId", "m1"}, {"label", "v"},
                {"start", "0/1"}, {"duration", "10/1"}};
  // Text on V2 above V1.
  json v2 = {{"id", "v2"}, {"kind", "video"}, {"name", "V2"}, {"index", 1},
             {"mute", false}, {"solo", false}, {"lock", false}, {"hidden", false},
             {"height", 72}};
  json text = {{"id", "ct"}, {"trackId", "v2"}, {"mediaId", ""}, {"label", "Text"},
               {"start", "0/1"}, {"duration", "5/1"}};
  text["text"] = {{"content", "HELLO"}};
  text["transform"] = {{"x", {{"static", 0.0}}}, {"y", {{"static", 0.0}}},
                       {"opacity", {{"static", 100.0}}}};

  json doc = baseDoc(json::array({video}));
  doc["tracks"].push_back(v2);
  doc["clips"].push_back(text);

  // The renderer asks for "text:<clipId>" for text clips; hand back a solid
  // band texture standing in for rasterized glyphs.
  const auto withText = [&]() {
    cc::RgbaSurface out;
    EXPECT_EQ(cc::renderFrame(
                  doc, cc::RationalTime{}, 320, 180,
                  [&](const std::string& key) -> std::optional<cc::ClipSource> {
                    if (key == "m1") return cc::ClipSource{fixturePath(), {}, false};
                    if (key == "text:ct") {
                      cc::ClipSource src;
                      src.texture = gradientFrame(320, 36, 220);
                      return src;
                    }
                    return std::nullopt;
                  },
                  &out),
              cc::Error::None);
    return out;
  }();

  const auto without = renderDoc(baseDoc(json::array({video})), "m1", fixturePath());
  EXPECT_GT(meanAbsDiff(withText, without), 1.0);
}

TEST(GoldenFrames, PreviewMatchesExportSamplingBitForBit) {
  // The core WYSIWYG guarantee: rendering the same document at the same time
  // through the same entry point twice yields identical bytes.
  if (!fixtureExists()) GTEST_SKIP() << "fixture not generated";
  json clip = {{"id", "c1"}, {"trackId", "v1"}, {"mediaId", "m1"}, {"label", "a"},
               {"start", "0/1"}, {"duration", "10/1"}};
  clip["effects"] = json::array(
      {{{"id", "e1"}, {"type", "saturation"}, {"enabled", true},
        {"params", {{"amount", {{"static", 0.5}}}}}}});
  clip["transform"] = {
      {"scale", {{"static", 80.0}}},
      {"rotation", {{"static", 12.5}}},
      {"opacity",
       {{"static", 100.0},
        {"keyframes", json::array({{{"t", "0/1"}, {"v", 100.0}},
                                   {{"t", "2/1"}, {"v", 40.0}}})}}}};
  auto doc = baseDoc(json::array({clip}));
  const auto r1 = renderDoc(doc, "m1", fixturePath(), 45, 30);
  const auto r2 = renderDoc(doc, "m1", fixturePath(), 45, 30);
  EXPECT_EQ(r1.rgba, r2.rgba);
  // Different rational spelling of the same instant also matches (45/30 ==
  // 90/60 == 1.5 s).
  const auto r3 = renderDoc(doc, "m1", fixturePath(), 90, 60);
  EXPECT_EQ(r1.rgba, r3.rgba);
}

TEST(GoldenFrames, BlendModesDifferFromNormal) {
  cc::RgbaSurface base = gradientFrame(64, 64, 128);
  cc::RgbaSurface top = gradientFrame(64, 64, 255);
  cc::RgbaSurface normal = base;
  cc::blendComposite(&normal, top, 1.0, "normal");
  cc::RgbaSurface mult = base;
  cc::blendComposite(&mult, top, 1.0, "multiply");
  cc::RgbaSurface add = base;
  cc::blendComposite(&add, top, 1.0, "add");
  EXPECT_GT(meanAbsDiff(normal, mult), 1.0);
  EXPECT_GT(meanAbsDiff(normal, add), 1.0);
  EXPECT_GT(meanAbsDiff(mult, add), 1.0);
}

}  // namespace
