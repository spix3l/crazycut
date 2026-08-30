// Area tracking (docs/03-features/tracking.md, TRK).
//
// Synthetic and deterministic throughout: no fixture media, no golden PNGs.
// The warp is exercised against surfaces whose expected result can be stated
// exactly, and the model against documents built in-test.

#include <array>
#include <cmath>
#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "model/project.h"
#include "track/solve.hpp"
#include "render/composite.h"
#include "render/effects.h"
#include "render/renderer.h"

namespace {

using json = nlohmann::json;

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

cc::RenderContext ctxOf(int w, int h) {
  cc::RenderContext ctx;
  ctx.sequenceWidth = w;
  ctx.sequenceHeight = h;
  return ctx;
}

// The quad a layer occupies when it exactly covers the canvas: TL,TR,BR,BL.
std::array<double, 8> canvasQuad(int w, int h) {
  return {0.0, 0.0, double(w), 0.0, double(w), double(h), 0.0, double(h)};
}

const uint8_t* pixel(const cc::RgbaSurface& s, int x, int y) {
  return s.rgba.data() + (static_cast<size_t>(y) * s.width + x) * 4;
}

json baseDoc(json clips, json trackers = json::array()) {
  return json{
      {"schema", "crazycut/project@1"},
      {"settings",
       {{"width", 1920}, {"height", 1080}, {"fps", "30/1"},
        {"audioSampleRate", 48000}, {"background", "#000000"}}},
      {"media",
       json::array({{{"id", "m1"}, {"duration", "10/1"}}})},
      {"tracks",
       json::array({
           {{"id", "v1"}, {"kind", "video"}, {"name", "V1"}, {"index", 0},
            {"mute", false}, {"solo", false}, {"lock", false}, {"hidden", false},
            {"height", 72}},
       })},
      {"clips", std::move(clips)},
      {"transitions", json::array()},
      {"markers", json::array()},
      {"trackers", std::move(trackers)}};
}

json oneClip(json extra = json::object(), json transform = json()) {
  json clip = {{"id", "c1"},      {"trackId", "v1"}, {"mediaId", "m1"},
               {"start", "0/1"},  {"duration", "4/1"}, {"sourceIn", "0/1"}};
  if (!extra.empty()) clip["extra"] = std::move(extra);
  if (!transform.is_null()) clip["transform"] = std::move(transform);
  return json::array({clip});
}

json validTracker(json overrides = json::object()) {
  json t = {{"id", "t1"},
            {"mediaId", "m1"},
            {"sourceClipId", "c1"},
            {"startTime", "0/1"},
            {"endTime", "2/1"},
            {"searchQuad", json::array({10, 10, 50, 10, 50, 40, 10, 40})},
            {"algorithm", "lk-homography"},
            {"algorithmVersion", 1},
            {"analysisWidth", 720},
            {"fps", "30/1"},
            {"path", json::array({10, 10, 50, 10, 50, 40, 10, 40,
                                  12, 10, 52, 10, 52, 40, 12, 40})},
            {"confidence", json::array({0.9, 0.8})}};
  for (auto& [k, v] : overrides.items()) t[k] = v;
  return t;
}

// --- Warp (TRK-20, TRK-23, TRK-25) ------------------------------------------

TEST(AreaTracking, IdentityQuadMatchesTheUntrackedPath) {
  // The whole safety argument for adding a third rasterizer branch: pinning a
  // layer to the rectangle it already occupies must not change a pixel, or
  // corner pin has silently degraded the ordinary case.
  const cc::RenderContext ctx = ctxOf(320, 180);
  const cc::RgbaSurface src = gradientFrame(320, 180, 90);

  cc::CompositedLayer plain;
  cc::RgbaSurface plainOut;
  cc::LayerBounds plainBounds;
  ASSERT_EQ(cc::rasterizeLayer(src, plain, ctx, "fit", &plainOut, &plainBounds),
            cc::Error::None);

  cc::CompositedLayer pinned;
  pinned.corners = canvasQuad(320, 180);
  cc::RgbaSurface pinnedOut;
  cc::LayerBounds pinnedBounds;
  ASSERT_EQ(cc::rasterizeLayer(src, pinned, ctx, "fit", &pinnedOut, &pinnedBounds),
            cc::Error::None);

  EXPECT_EQ(plainOut.rgba, pinnedOut.rgba);
  EXPECT_EQ(plainBounds.x0, pinnedBounds.x0);
  EXPECT_EQ(plainBounds.y0, pinnedBounds.y0);
  EXPECT_EQ(plainBounds.x1, pinnedBounds.x1);
  EXPECT_EQ(plainBounds.y1, pinnedBounds.y1);
}

TEST(AreaTracking, TranslatedQuadMatchesAnEquivalentPositionOffset) {
  // A quad that is the canvas rect shifted right by 40 px must land where the
  // ordinary transform path puts the same layer at x = 40.
  const cc::RenderContext ctx = ctxOf(320, 180);
  const cc::RgbaSurface src = gradientFrame(320, 180, 20);

  cc::CompositedLayer moved;
  moved.x = 40.0;
  cc::RgbaSurface movedOut;
  ASSERT_EQ(cc::rasterizeLayer(src, moved, ctx, "fit", &movedOut, nullptr),
            cc::Error::None);

  cc::CompositedLayer pinned;
  pinned.corners = std::array<double, 8>{40, 0, 360, 0, 360, 180, 40, 180};
  cc::RgbaSurface pinnedOut;
  ASSERT_EQ(cc::rasterizeLayer(src, pinned, ctx, "fit", &pinnedOut, nullptr),
            cc::Error::None);

  // Both resample, so they agree closely rather than exactly.
  EXPECT_LT(meanAbsDiff(movedOut, pinnedOut), 1.0);
}

TEST(AreaTracking, QuadConfinesTheLayerToItsFootprint) {
  const cc::RenderContext ctx = ctxOf(320, 180);
  const cc::RgbaSurface src = gradientFrame(64, 64, 255);

  cc::CompositedLayer pinned;
  pinned.corners = std::array<double, 8>{100, 40, 200, 50, 190, 140, 90, 120};
  cc::RgbaSurface out;
  cc::LayerBounds bounds;
  ASSERT_EQ(cc::rasterizeLayer(src, pinned, ctx, "fit", &out, &bounds),
            cc::Error::None);

  ASSERT_FALSE(bounds.empty());
  // The footprint cannot escape the quad's bounding box.
  EXPECT_GE(bounds.x0, 90);
  EXPECT_LE(bounds.x1, 200);
  EXPECT_GE(bounds.y0, 40);
  EXPECT_LE(bounds.y1, 140);
  // Well outside the quad nothing was written.
  EXPECT_EQ(pixel(out, 5, 5)[3], 0);
  EXPECT_EQ(pixel(out, 310, 170)[3], 0);
  // Well inside it, something was.
  EXPECT_GT(pixel(out, 145, 90)[3], 0);
}

TEST(AreaTracking, PerspectiveQuadIsNotAffine) {
  // A trapezoid must actually foreshorten: the narrow end has to compress more
  // source rows than the wide end. An affine fallback would space them evenly.
  const cc::RenderContext ctx = ctxOf(320, 180);
  cc::RgbaSurface src = gradientFrame(128, 128, 0);

  cc::CompositedLayer pinned;
  // Wide at the top, narrow at the bottom.
  pinned.corners = std::array<double, 8>{40, 20, 280, 20, 200, 160, 120, 160};
  cc::RgbaSurface out;
  ASSERT_EQ(cc::rasterizeLayer(src, pinned, ctx, "fit", &out, nullptr),
            cc::Error::None);

  // Green channel encodes the source row. Sample the centre column at three
  // heights; a perspective map advances it faster near the narrow end.
  const int mid = 160;
  const int gTop = pixel(out, mid, 40)[1];
  const int gMid = pixel(out, mid, 90)[1];
  const int gBot = pixel(out, mid, 150)[1];
  ASSERT_LT(gTop, gMid);
  ASSERT_LT(gMid, gBot);
  EXPECT_GT(gBot - gMid, gMid - gTop)
      << "expected foreshortening, got an evenly spaced (affine) map";
}

TEST(AreaTracking, DegenerateQuadsRenderNothing) {
  const cc::RenderContext ctx = ctxOf(320, 180);
  const cc::RgbaSurface src = gradientFrame(64, 64, 128);

  const std::array<double, 8> collapsed{50, 50, 50, 50, 50, 50, 50, 50};
  const std::array<double, 8> bowtie{50, 50, 150, 50, 50, 150, 150, 150};
  const std::array<double, 8> sliver{50, 50, 50.4, 50, 50.4, 50.4, 50, 50.4};

  for (const auto& quad : {collapsed, bowtie, sliver}) {
    cc::CompositedLayer pinned;
    pinned.corners = quad;
    cc::RgbaSurface out;
    cc::LayerBounds bounds;
    ASSERT_EQ(cc::rasterizeLayer(src, pinned, ctx, "fit", &out, &bounds),
              cc::Error::None);
    EXPECT_TRUE(bounds.empty());
    // TRK-25: nothing written, rather than undefined pixels.
    for (const uint8_t byte : out.rgba) EXPECT_EQ(byte, 0);
  }
}

TEST(AreaTracking, CornersScaleWithThePreviewCanvas) {
  // TRK-20 stores corners in document px. A half-size preview must pin the
  // overlay to the same *relative* place the delivered frame does.
  const json transform = {
      {"corners", json::array({480, 270, 1440, 270, 1440, 810, 480, 810})}};
  cc::CompositedLayer full, half;
  cc::RenderContext fullCtx = ctxOf(1920, 1080);
  cc::RenderContext halfCtx = ctxOf(960, 540);
  halfCtx.positionScaleX = 0.5;
  halfCtx.positionScaleY = 0.5;

  cc::applyTransformJson(transform, cc::RationalTime{}, fullCtx, &full);
  cc::applyTransformJson(transform, cc::RationalTime{}, halfCtx, &half);

  ASSERT_TRUE(full.corners.has_value());
  ASSERT_TRUE(half.corners.has_value());
  for (int i = 0; i < 8; ++i) {
    EXPECT_DOUBLE_EQ((*half.corners)[i] * 2.0, (*full.corners)[i]) << "component " << i;
  }
}

TEST(AreaTracking, CornersAreKeyframeableThroughTheSharedEvaluator) {
  const json transform = {
      {"corners",
       {{"static", json::array({0, 0, 100, 0, 100, 100, 0, 100})},
        {"keyframes",
         json::array({{{"t", "0/1"},
                       {"v", json::array({0, 0, 100, 0, 100, 100, 0, 100})},
                       {"interp", "linear"}},
                      {{"t", "1/1"},
                       {"v", json::array({100, 0, 200, 0, 200, 100, 100, 100})},
                       {"interp", "linear"}}})}}}};
  cc::CompositedLayer layer;
  const cc::RenderContext ctx = ctxOf(1920, 1080);
  cc::applyTransformJson(transform, cc::RationalTime{1, 2}, ctx, &layer);
  ASSERT_TRUE(layer.corners.has_value());
  // Halfway between the two quads: every x advanced by 50.
  EXPECT_DOUBLE_EQ((*layer.corners)[0], 50.0);
  EXPECT_DOUBLE_EQ((*layer.corners)[2], 150.0);
  EXPECT_DOUBLE_EQ((*layer.corners)[1], 0.0);
}

TEST(AreaTracking, MalformedCornersAreIgnoredRatherThanPartlyApplied) {
  for (const json bad : {json::array({0, 0, 1, 1}),                    // too short
                         json::array({0, 0, 1, 0, 1, 1, 0, "x"}),      // not numeric
                         json("nope")}) {
    cc::CompositedLayer layer;
    cc::applyTransformJson(json{{"corners", bad}}, cc::RationalTime{},
                           ctxOf(1920, 1080), &layer);
    EXPECT_FALSE(layer.corners.has_value()) << bad.dump();
  }
}

TEST(AreaTracking, PinnedClipIsExcludedFromTheExportPassthrough) {
  // TRK-24. A corner-pinned clip is a projective warp, so the encoder can never
  // copy its source frames through untouched.
  const json quad = json::array({0, 0, 1920, 0, 1920, 1080, 0, 1080});
  const json doc = baseDoc(oneClip(json::object(), json{{"corners", quad}}));
  cc::RenderIndex index(doc);
  const auto resolve = [](const std::string&) -> std::optional<cc::ClipSource> {
    cc::ClipSource src;
    src.path = "/nonexistent/media.mp4";
    return src;
  };
  EXPECT_TRUE(cc::passthroughClips(index, 1920, 1080, resolve).empty());

  // Control: the same document without the pin is eligible.
  const json plain = baseDoc(oneClip());
  cc::RenderIndex plainIndex(plain);
  EXPECT_EQ(cc::passthroughClips(plainIndex, 1920, 1080, resolve).count("c1"), 1u);
}

// --- Model (TRK-13, TRK-16, TRK-22) -----------------------------------------

cc::ProjectSnapshot loaded(const json& doc, bool repair = true) {
  cc::ProjectSnapshot snapshot;
  EXPECT_EQ(snapshot.load(doc.dump(), repair), cc::Error::None);
  return snapshot;
}

bool hasIssue(const cc::ProjectSnapshot& s, const std::string& code) {
  for (const auto& issue : s.issues()) {
    if (issue.code == code) return true;
  }
  return false;
}

TEST(AreaTracking, ValidTrackerSurvivesARoundTrip) {
  const json doc = baseDoc(oneClip(), json::array({validTracker()}));
  const auto snapshot = loaded(doc);
  ASSERT_EQ(snapshot.document()["trackers"].size(), 1u);
  const json& t = snapshot.document()["trackers"][0];
  EXPECT_EQ(t["id"], "t1");
  EXPECT_EQ(t["path"].size(), 16u);
  // Times and fps are canonicalized to "n/d" like every other rational.
  EXPECT_TRUE(t["startTime"].is_string());
  EXPECT_TRUE(t["endTime"].is_string());
  EXPECT_TRUE(t["fps"].is_string());
  EXPECT_FALSE(hasIssue(snapshot, "invalid_tracker"));
}

TEST(AreaTracking, MissingTrackersArrayIsCreated) {
  json doc = baseDoc(oneClip());
  doc.erase("trackers");
  const auto snapshot = loaded(doc);
  ASSERT_TRUE(snapshot.document()["trackers"].is_array());
  EXPECT_TRUE(snapshot.document()["trackers"].empty());
}

TEST(AreaTracking, CorruptTrackersAreQuarantinedWithoutLosingSiblings) {
  // TRK-16 / acceptance 8: one bad tracker must not take a good one with it.
  const json cases[] = {
      validTracker({{"id", ""}}),
      validTracker({{"mediaId", "missing"}}),
      validTracker({{"sourceClipId", "missing"}}),
      validTracker({{"searchQuad", json::array({1, 2, 3})}}),
      validTracker({{"path", json::array({1, 2, 3})}}),          // not a multiple of 8
      validTracker({{"path", json::array()}}),                   // empty
      validTracker({{"confidence", json::array({0.5})}}),        // wrong length
      validTracker({{"fps", "0/1"}}),
      validTracker({{"endTime", "99/1"}}),                       // beyond the clip
      validTracker({{"startTime", "3/1"}, {"endTime", "2/1"}}),  // inverted
  };
  for (const json& bad : cases) {
    json broken = bad;
    broken["id"] = bad["id"].get<std::string>().empty() ? "" : "bad";
    const json good = validTracker({{"id", "good"}});
    const auto snapshot = loaded(baseDoc(oneClip(), json::array({broken, good})));
    EXPECT_TRUE(hasIssue(snapshot, "invalid_tracker")) << bad.dump();
    ASSERT_EQ(snapshot.document()["trackers"].size(), 1u) << bad.dump();
    EXPECT_EQ(snapshot.document()["trackers"][0]["id"], "good") << bad.dump();
    // The rest of the document is untouched.
    EXPECT_EQ(snapshot.document()["clips"].size(), 1u);
  }
}

TEST(AreaTracking, DuplicateTrackerIdsAreRejected) {
  const auto snapshot =
      loaded(baseDoc(oneClip(), json::array({validTracker(), validTracker()})));
  EXPECT_TRUE(hasIssue(snapshot, "invalid_tracker"));
  EXPECT_EQ(snapshot.document()["trackers"].size(), 1u);
}

TEST(AreaTracking, PinToAMissingTrackerIsDropped) {
  // TRK-22: never leave a clip asking for a pose nothing can supply.
  const json pin = {{"trackPin", {{"trackerId", "gone"}, {"mode", "cornerPin"}}}};
  const auto snapshot = loaded(baseDoc(oneClip(pin), json::array({validTracker()})));
  EXPECT_TRUE(hasIssue(snapshot, "dangling_track_pin"));
  EXPECT_FALSE(snapshot.document()["clips"][0]["extra"].contains("trackPin"));
}

TEST(AreaTracking, PinToASurvivingTrackerIsKept) {
  const json pin = {{"trackPin", {{"trackerId", "t1"}, {"mode", "cornerPin"}}}};
  const auto snapshot = loaded(baseDoc(oneClip(pin), json::array({validTracker()})));
  EXPECT_FALSE(hasIssue(snapshot, "dangling_track_pin"));
  ASSERT_TRUE(snapshot.document()["clips"][0]["extra"].contains("trackPin"));
  EXPECT_EQ(snapshot.document()["clips"][0]["extra"]["trackPin"]["trackerId"], "t1");
}

TEST(AreaTracking, PinIsDroppedWhenItsTrackerIsQuarantined) {
  const json pin = {{"trackPin", {{"trackerId", "t1"}, {"mode", "cornerPin"}}}};
  const json broken = validTracker({{"confidence", json::array({0.5})}});
  const auto snapshot = loaded(baseDoc(oneClip(pin), json::array({broken})));
  EXPECT_TRUE(hasIssue(snapshot, "invalid_tracker"));
  EXPECT_FALSE(snapshot.document()["clips"][0]["extra"].contains("trackPin"));
}

TEST(AreaTracking, TransformKeyframesAreValidatedLikeEffectKeyframes) {
  // The transform's params were never walked by the loader. A tracked `corners`
  // quad rides on them, so a key past the end of the clip must be caught.
  json clips = oneClip(json::object(),
                       json{{"corners",
                             {{"keyframes",
                               json::array({{{"t", "99/1"},
                                             {"v", json::array({0, 0, 1, 0, 1, 1, 0, 1})},
                                             {"interp", "linear"}}})}}}});
  const auto snapshot = loaded(baseDoc(std::move(clips)));
  EXPECT_TRUE(hasIssue(snapshot, "invalid_keyframe_time"));
  EXPECT_TRUE(snapshot.document()["clips"].empty());
}

TEST(AreaTracking, UnknownTrackerFieldsSurviveTheLoader) {
  // 02-data-model.md §9: forward-safe. A future field must round-trip verbatim.
  const auto snapshot =
      loaded(baseDoc(oneClip(), json::array({validTracker({{"futureField", 7}})})));
  ASSERT_EQ(snapshot.document()["trackers"].size(), 1u);
  EXPECT_EQ(snapshot.document()["trackers"][0]["futureField"], 7);
}

// --- Solver (TRK-5..TRK-12) --------------------------------------------------

std::string panFixturePath() {
  if (const char* env = std::getenv("CC_TRACK_FIXTURE")) return env;
  return std::string(CC_SOURCE_DIR) + "/../fixtures/media/track-pan.mp4";
}

bool panFixtureExists() {
  std::ifstream f(panFixturePath());
  return f.good();
}

// The fixture pans a textured still by exactly 2 px per frame in x
// (tools/make-fixture.sh), so a tracked region's ground truth is known.
cc::TrackRequest panRequest() {
  cc::TrackRequest request;
  request.mediaPath = panFixturePath();
  request.searchQuad = {240, 120, 400, 120, 400, 240, 240, 240};
  request.startSec = 0.0;
  request.endSec = 2.9;
  request.fps = 30.0;
  request.analysisWidth = 640;
  request.sourceWidth = 640;
  return request;
}

TEST(AreaTracking, DecimationOnlyUsesStridesThatDivideTheSpan) {
  // The stored path is addressed by index at a fixed rate, so a stride that
  // leaves a ragged final gap would put every sample after it at the wrong
  // time. 12 samples span 11 intervals, whose only divisors are 1 and 11.
  std::vector<cc::TrackSample> flat(12);
  for (auto& s : flat) s.quad = {0, 0, 10, 0, 10, 10, 0, 10};
  const int stride = cc::decimationStride(flat, 0.25);
  EXPECT_EQ(11 % stride, 0);
  EXPECT_EQ(stride, 11) << "a perfectly static path should collapse hard";
}

TEST(AreaTracking, DecimationKeepsMovingPathsIntact) {
  // A path that swings back and forth cannot be reconstructed from its ends.
  std::vector<cc::TrackSample> zigzag(13);
  for (size_t i = 0; i < zigzag.size(); ++i) {
    const double bump = (i % 2 == 0) ? 0.0 : 40.0;
    zigzag[i].quad = {bump, 0, 10 + bump, 0, 10 + bump, 10, bump, 10};
  }
  EXPECT_EQ(cc::decimationStride(zigzag, 0.25), 1);
}

TEST(AreaTracking, DecimationRespectsItsTolerance) {
  // A straight ramp is exactly reconstructible, so it decimates fully.
  std::vector<cc::TrackSample> ramp(11);
  for (size_t i = 0; i < ramp.size(); ++i) {
    const double x = static_cast<double>(i);
    ramp[i].quad = {x, 0, x + 10, 0, x + 10, 10, x, 10};
  }
  EXPECT_EQ(cc::decimationStride(ramp, 0.25), 10);
}

TEST(AreaTracking, QuantizationMatchesTheStoredPrecision) {
  std::vector<cc::TrackSample> samples(1);
  samples[0].quad = {1.23456, -2.99999, 0, 0, 0, 0, 0, 0};
  samples[0].confidence = 1.5;  // out of range
  cc::quantizePath(&samples);
  EXPECT_DOUBLE_EQ(samples[0].quad[0], 1.235);
  EXPECT_DOUBLE_EQ(samples[0].quad[1], -3.0);
  EXPECT_DOUBLE_EQ(samples[0].confidence, 1.0);
}

TEST(AreaTracking, SolverRejectsNonsenseRequests) {
  if (!cc::trackingAvailable()) GTEST_SKIP() << "built without CC_WITH_TRACKING";
  cc::TrackResult result;
  const auto noop = [](double) { return true; };

  cc::TrackRequest noPath = panRequest();
  noPath.mediaPath.clear();
  EXPECT_EQ(cc::solveRegion(noPath, &result, noop), cc::Error::InvalidArgument);

  cc::TrackRequest noRange = panRequest();
  noRange.endSec = noRange.startSec;
  EXPECT_EQ(cc::solveRegion(noRange, &result, noop), cc::Error::InvalidArgument);

  cc::TrackRequest noFps = panRequest();
  noFps.fps = 0.0;
  EXPECT_EQ(cc::solveRegion(noFps, &result, noop), cc::Error::InvalidArgument);

  EXPECT_EQ(cc::solveRegion(panRequest(), nullptr, noop),
            cc::Error::InvalidArgument);
}

TEST(AreaTracking, SolverRecoversAKnownPan) {
  if (!cc::trackingAvailable()) GTEST_SKIP() << "built without CC_WITH_TRACKING";
  if (!panFixtureExists()) GTEST_SKIP() << "run tools/make-fixture.sh";

  cc::TrackResult result;
  ASSERT_EQ(cc::solveRegion(panRequest(), &result, [](double) { return true; }),
            cc::Error::None);
  ASSERT_GT(result.samples.size(), 60u);

  double worstX = 0.0, worstY = 0.0, worstWidth = 0.0;
  for (size_t i = 0; i < result.samples.size(); ++i) {
    const auto& quad = result.samples[i].quad;
    const double expectedX = 240.0 - 2.0 * i * result.stride;
    worstX = std::max(worstX, std::abs(quad[0] - expectedX));
    worstY = std::max(worstY, std::abs(quad[1] - 120.0));
    worstWidth = std::max(worstWidth, std::abs((quad[2] - quad[0]) - 160.0));
    // Confidence is meaningful, not decorative: a clean textured pan is the
    // easiest thing there is, so a low reading here means the metric is wrong.
    EXPECT_GT(result.samples[i].confidence, 0.5) << "sample " << i;
  }
  // Over a 174 px pan. The tolerance is drift, not per-frame noise.
  EXPECT_LT(worstX, 8.0) << "tracked x drifted";
  EXPECT_LT(worstY, 3.0) << "tracked y should not move at all";
  EXPECT_LT(worstWidth, 3.0) << "tracked width should not change";
}

TEST(AreaTracking, SolverHonoursASourceWidthUnlikeTheAnalysisWidth) {
  // The region is authored in *source* pixels and the solver works in analysis
  // pixels, so it needs the ratio between them. Every earlier test solved the
  // 640-wide fixture at analysisWidth 640, where that ratio is 1 whether it is
  // computed correctly or not — which is exactly how a bug that always left it
  // at 1 survived. Solve the same region downscaled and the answer must not
  // move.
  if (!cc::trackingAvailable()) GTEST_SKIP() << "built without CC_WITH_TRACKING";
  if (!panFixtureExists()) GTEST_SKIP() << "run tools/make-fixture.sh";

  const auto noop = [](double) { return true; };
  cc::TrackResult full, half;

  cc::TrackRequest atSource = panRequest();
  atSource.analysisWidth = 640;
  atSource.sourceWidth = 640;
  ASSERT_EQ(cc::solveRegion(atSource, &full, noop), cc::Error::None);

  cc::TrackRequest atHalf = panRequest();
  atHalf.analysisWidth = 320;
  atHalf.sourceWidth = 640;
  ASSERT_EQ(cc::solveRegion(atHalf, &half, noop), cc::Error::None);

  // Both report in source pixels, so they start on the drawn region and travel
  // together. Half resolution is less precise, not differently scaled.
  ASSERT_FALSE(full.samples.empty());
  ASSERT_FALSE(half.samples.empty());
  EXPECT_NEAR(half.samples.front().quad[0], 240.0, 1.0);
  EXPECT_NEAR(half.samples.front().quad[2], 400.0, 1.0);

  // Both travel the same way and a long way. They do *not* agree closely: at
  // half resolution this fixture's features are half the size and the solve
  // under-travels by about a third. That is a real accuracy cost, and it is why
  // the default analysis width is the source's own rather than a fixed number
  // that might be smaller.
  const double fullTravel =
      full.samples.front().quad[0] - full.samples.back().quad[0];
  const double halfTravel =
      half.samples.front().quad[0] - half.samples.back().quad[0];
  EXPECT_GT(fullTravel, 150.0);
  EXPECT_GT(halfTravel, 50.0);
  EXPECT_LT(halfTravel, fullTravel + 5.0);
}

TEST(AreaTracking, SolverRefusesWhenItCannotKnowTheSourceWidth) {
  // Guessing 1:1 here is what put the region somewhere else in the analysis
  // frame, where it found nothing and held its opening pose for the whole clip
  // — a silent wrong answer. Refusing is the only honest option.
  if (!cc::trackingAvailable()) GTEST_SKIP() << "built without CC_WITH_TRACKING";
  cc::TrackRequest request = panRequest();
  request.mediaPath = std::string(CC_SOURCE_DIR) + "/../fixtures/media/none.mp4";
  request.sourceWidth = 0;
  cc::TrackResult result;
  EXPECT_NE(cc::solveRegion(request, &result, [](double) { return true; }),
            cc::Error::None);
}

TEST(AreaTracking, SolvingTwiceGivesTheSamePathBitForBit) {
  // TRK-9 / acceptance 7. RANSAC draws from a seeded RNG and the solve runs
  // single-threaded precisely so this holds on any machine.
  if (!cc::trackingAvailable()) GTEST_SKIP() << "built without CC_WITH_TRACKING";
  if (!panFixtureExists()) GTEST_SKIP() << "run tools/make-fixture.sh";

  cc::TrackResult first, second;
  const auto noop = [](double) { return true; };
  ASSERT_EQ(cc::solveRegion(panRequest(), &first, noop), cc::Error::None);
  ASSERT_EQ(cc::solveRegion(panRequest(), &second, noop), cc::Error::None);

  ASSERT_EQ(first.samples.size(), second.samples.size());
  EXPECT_EQ(first.stride, second.stride);
  for (size_t i = 0; i < first.samples.size(); ++i) {
    EXPECT_EQ(first.samples[i].quad, second.samples[i].quad) << "sample " << i;
    EXPECT_DOUBLE_EQ(first.samples[i].confidence, second.samples[i].confidence);
  }
}

TEST(AreaTracking, SolverReportsMonotonicProgressAndCanBeCancelled) {
  if (!cc::trackingAvailable()) GTEST_SKIP() << "built without CC_WITH_TRACKING";
  if (!panFixtureExists()) GTEST_SKIP() << "run tools/make-fixture.sh";

  double lastFraction = -1.0;
  int calls = 0;
  cc::TrackResult result;
  const cc::Error error =
      cc::solveRegion(panRequest(), &result, [&](double fraction) {
        EXPECT_GE(fraction, lastFraction) << "progress went backwards";
        EXPECT_GE(fraction, 0.0);
        EXPECT_LE(fraction, 1.0);
        lastFraction = fraction;
        // TRK-10: returning false must stop the run.
        return ++calls < 5;
      });
  EXPECT_EQ(error, cc::Error::Cancelled);
  EXPECT_EQ(calls, 5);
  // Nothing partial escapes: the caller's result is untouched.
  EXPECT_TRUE(result.samples.empty());
}

TEST(AreaTracking, SolvedQuadsAreUsableByTheCompositor) {
  // The solver's output feeds `corners` directly, so every quad it produces has
  // to satisfy the rasterizer's own usability rule or the overlay blinks out.
  if (!cc::trackingAvailable()) GTEST_SKIP() << "built without CC_WITH_TRACKING";
  if (!panFixtureExists()) GTEST_SKIP() << "run tools/make-fixture.sh";

  cc::TrackResult result;
  ASSERT_EQ(cc::solveRegion(panRequest(), &result, [](double) { return true; }),
            cc::Error::None);
  const cc::RenderContext ctx = ctxOf(640, 360);
  const cc::RgbaSurface src = gradientFrame(64, 64, 200);
  for (size_t i = 0; i < result.samples.size(); ++i) {
    cc::CompositedLayer layer;
    layer.corners = result.samples[i].quad;
    cc::RgbaSurface out;
    cc::LayerBounds bounds;
    ASSERT_EQ(cc::rasterizeLayer(src, layer, ctx, "fit", &out, &bounds),
              cc::Error::None);
    EXPECT_FALSE(bounds.empty()) << "sample " << i << " rendered nothing";
  }
}

TEST(AreaTracking, PinnedClipRendersIdenticallyEveryTime) {
  // Acceptance 5, the WYSIWYG claim: preview and export are the same call, so
  // what has to hold is that the same document at the same instant produces
  // identical bytes — including through the corner-pin path, and including
  // when the instant is spelled as a different rational.
  if (!panFixtureExists()) GTEST_SKIP() << "run tools/make-fixture.sh";

  json clip = {{"id", "c1"},   {"trackId", "v1"}, {"mediaId", "m1"},
               {"label", "a"}, {"start", "0/1"},  {"duration", "3/1"}};
  clip["transform"] = {
      {"corners",
       {{"static", json::array({200, 100, 1500, 140, 1400, 900, 300, 850})},
        {"keyframes",
         json::array(
             {{{"t", "0/1"},
               {"v", json::array({200, 100, 1500, 140, 1400, 900, 300, 850})},
               {"interp", "linear"}},
              {{"t", "2/1"},
               {"v", json::array({260, 120, 1560, 100, 1440, 940, 340, 900})},
               {"interp", "linear"}}})}}}};

  json doc = baseDoc(json::array({clip}));
  doc["media"] = json::array({{{"id", "m1"}, {"duration", "3/1"}}});

  const std::map<std::string, std::string> paths{{"m1", panFixturePath()}};
  auto render = [&](int num, int den) {
    cc::RgbaSurface out;
    EXPECT_EQ(cc::renderFrame(doc, cc::RationalTime{num, den}.normalized(), 320,
                              180, paths, &out),
              cc::Error::None);
    return out;
  };

  const auto a = render(45, 30);
  const auto b = render(45, 30);
  EXPECT_EQ(a.rgba, b.rgba);
  // 45/30 and 90/60 are the same instant.
  EXPECT_EQ(a.rgba, render(90, 60).rgba);
  // And the pin actually drew something, or the comparison is vacuous.
  EXPECT_NE(std::count(a.rgba.begin(), a.rgba.end(), 0),
            static_cast<long>(a.rgba.size()));
}

}  // namespace
