#include "track/solve.hpp"

#include <algorithm>
#include <cmath>

#include <nlohmann/json.hpp>

#include "media/frame.h"
#include "media/probe.h"

#ifdef CC_HAS_TRACKING
#include <opencv2/calib3d.hpp>
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/video/tracking.hpp>
#endif

namespace cc {
namespace {

// Solver tuning. These are the knobs that decide whether a track survives a
// fast pan; they are named rather than inlined so the spec's behaviour claims
// have one place to point at.
constexpr int kMaxFeatures = 400;
constexpr double kFeatureQuality = 0.01;
constexpr double kMinFeatureDistance = 6.0;
// A point is kept only if tracking it forward and then back lands within this
// many pixels of where it started. Forward-backward error is what stops a
// feature that slid onto the background from dragging the quad with it.
constexpr double kMaxForwardBackwardError = 1.0;
constexpr double kRansacReprojectionPx = 3.0;
// Below this many surviving correspondences a homography is not worth fitting.
constexpr int kMinCorrespondences = 8;
// And below this many RANSAC *inliers* the fit is noise agreeing with itself.
// The inlier ratio alone does not catch that: a handful of mutually consistent
// bad matches produce a ratio of 1.0 and a quad that flies off the canvas.
constexpr int kMinInliers = 12;
// How far the quad may move, grow or shrink between two adjacent frames before
// the step is rejected as implausible. At the frame rates we solve at, real
// motion is smooth; a violent step means the homography fitted noise.
constexpr double kMaxCornerStepFraction = 0.15;  // of the frame diagonal
constexpr double kMaxAreaGrowth = 1.6;
// Cumulative bounds against the *original* region. Per-step limits let a slow
// bleed accumulate over hundreds of frames into a quad that has left the
// picture; these stop it, and the confidence readout is what tells the user the
// track stopped following (TRK-8).
constexpr double kMaxCumulativeAreaRatio = 6.0;
constexpr double kMaxOutsideFrameFraction = 0.75;
// Re-seed when the usable feature count falls below this fraction of the last
// seed, so a quad that is slowly shedding points recovers before it starves.
constexpr double kReseedFraction = 0.5;
constexpr double kReseedConfidence = 0.6;
// How far a decimated path may drift from the full solve, in source px. A
// quarter of a pixel is below what the compositor's bilinear sampling can show.
constexpr double kDecimationTolerancePx = 0.25;

double clamp01(double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); }

// Linear reconstruction error of dropping every sample between kept ones.
double decimationError(const std::vector<TrackSample>& samples, int stride) {
  double worst = 0.0;
  for (size_t i = 0; i < samples.size(); ++i) {
    const size_t lo = (i / stride) * stride;
    const size_t hi = std::min(lo + stride, samples.size() - 1);
    const double t = hi == lo ? 0.0
                              : static_cast<double>(i - lo) / static_cast<double>(hi - lo);
    for (int k = 0; k < 8; ++k) {
      const double predicted =
          samples[lo].quad[k] + (samples[hi].quad[k] - samples[lo].quad[k]) * t;
      worst = std::max(worst, std::abs(predicted - samples[i].quad[k]));
    }
  }
  return worst;
}

}  // namespace

int decimationStride(const std::vector<TrackSample>& samples, double tolerancePx,
                     int maxStride) {
  if (samples.size() < 3 || maxStride < 1) return 1;
  // Only strides that divide the span exactly are considered: the stored path
  // is addressed by index at a fixed rate, so a ragged final gap would put
  // every sample after it at the wrong time.
  const int span = static_cast<int>(samples.size()) - 1;
  const int limit = std::min(maxStride, span);
  int best = 1;
  for (int stride = 2; stride <= limit; ++stride) {
    if (span % stride != 0) continue;
    if (decimationError(samples, stride) > tolerancePx) continue;
    best = stride;
  }
  return best;
}

void quantizePath(std::vector<TrackSample>* samples) {
  if (samples == nullptr) return;
  for (auto& sample : *samples) {
    for (double& v : sample.quad) v = std::round(v * 1000.0) / 1000.0;
    sample.confidence = std::round(clamp01(sample.confidence) * 1000.0) / 1000.0;
  }
}

#ifndef CC_HAS_TRACKING

bool trackingAvailable() { return false; }

Error solveRegion(const TrackRequest&, TrackResult*, const TrackProgress&) {
  setLastError("this build has no area tracking support");
  return Error::InvalidArgument;
}

#else

bool trackingAvailable() { return true; }

namespace {

cv::Mat grayFrom(const DecodedFrame& frame) {
  const cv::Mat rgba(frame.height, frame.width, CV_8UC4,
                     const_cast<uint8_t*>(frame.rgba.data()));
  cv::Mat gray;
  cv::cvtColor(rgba, gray, cv::COLOR_RGBA2GRAY);
  return gray;
}

std::vector<cv::Point2f> quadPoints(const TrackQuad& quad, double scale) {
  std::vector<cv::Point2f> points(4);
  for (int i = 0; i < 4; ++i) {
    points[i] = cv::Point2f(static_cast<float>(quad[2 * i] * scale),
                            static_cast<float>(quad[2 * i + 1] * scale));
  }
  return points;
}

TrackQuad quadFrom(const std::vector<cv::Point2f>& points, double scale) {
  TrackQuad quad{};
  for (int i = 0; i < 4; ++i) {
    quad[2 * i] = points[i].x / scale;
    quad[2 * i + 1] = points[i].y / scale;
  }
  return quad;
}

// Features are only ever sought inside the tracked region: seeding from the
// whole frame would fit the homography to the background, which is exactly the
// motion we do not want.
cv::Mat quadMask(const cv::Size& size, const std::vector<cv::Point2f>& quad) {
  cv::Mat mask = cv::Mat::zeros(size, CV_8UC1);
  std::vector<cv::Point> poly;
  poly.reserve(4);
  for (const auto& p : quad) {
    poly.emplace_back(cvRound(p.x), cvRound(p.y));
  }
  cv::fillConvexPoly(mask, poly, cv::Scalar(255));
  return mask;
}

std::vector<cv::Point2f> seedFeatures(const cv::Mat& gray,
                                      const std::vector<cv::Point2f>& quad) {
  std::vector<cv::Point2f> features;
  const cv::Mat mask = quadMask(gray.size(), quad);
  if (cv::countNonZero(mask) < 16) return features;
  cv::goodFeaturesToTrack(gray, features, kMaxFeatures, kFeatureQuality,
                          kMinFeatureDistance, mask);
  return features;
}

bool quadIsSane(const std::vector<cv::Point2f>& quad, const cv::Size& frame) {
  double twiceArea = 0.0;
  int sign = 0;
  for (int i = 0; i < 4; ++i) {
    const int j = (i + 1) % 4, k = (i + 2) % 4;
    const double ax = quad[j].x - quad[i].x, ay = quad[j].y - quad[i].y;
    const double bx = quad[k].x - quad[j].x, by = quad[k].y - quad[j].y;
    const double cross = ax * by - ay * bx;
    if (!std::isfinite(cross) || cross == 0.0) return false;
    const int s = cross > 0 ? 1 : -1;
    if (sign == 0) sign = s;
    else if (s != sign) return false;
    twiceArea += quad[i].x * quad[j].y - quad[j].x * quad[i].y;
  }
  if (std::abs(twiceArea) < 8.0) return false;
  // A tracked region belongs to what is on screen. Allowing it to wander far
  // outside the frame only lets a bad homography accumulate somewhere the user
  // can never see it is wrong.
  const double marginX = frame.width * kMaxOutsideFrameFraction;
  const double marginY = frame.height * kMaxOutsideFrameFraction;
  for (const auto& p : quad) {
    if (!std::isfinite(p.x) || !std::isfinite(p.y)) return false;
    if (p.x < -marginX || p.x > frame.width + marginX) return false;
    if (p.y < -marginY || p.y > frame.height + marginY) return false;
  }
  return true;
}

// Rejects a frame-to-frame step that no real motion produces: a corner jumping
// a sixth of the frame, or the region's area changing by more than half, in one
// frame. This is the check that distinguishes "the subject moved fast" from
// "the solve came apart" (TRK-8) — the inlier ratio cannot tell them apart.
bool stepIsPlausible(const std::vector<cv::Point2f>& before,
                     const std::vector<cv::Point2f>& after,
                     const cv::Size& frame) {
  const double diagonal =
      std::sqrt(static_cast<double>(frame.width) * frame.width +
                static_cast<double>(frame.height) * frame.height);
  const double maxStep = diagonal * kMaxCornerStepFraction;
  for (int i = 0; i < 4; ++i) {
    const double dx = after[i].x - before[i].x;
    const double dy = after[i].y - before[i].y;
    if (std::sqrt(dx * dx + dy * dy) > maxStep) return false;
  }
  const double areaBefore = std::abs(cv::contourArea(before));
  const double areaAfter = std::abs(cv::contourArea(after));
  if (areaBefore <= 0.0 || areaAfter <= 0.0) return false;
  const double ratio = areaAfter / areaBefore;
  return ratio <= kMaxAreaGrowth && ratio >= 1.0 / kMaxAreaGrowth;
}

}  // namespace

Error solveRegion(const TrackRequest& request, TrackResult* out,
                  const TrackProgress& onProgress) {
  if (out == nullptr || request.mediaPath.empty()) {
    setLastError("tracking needs a media path and an output");
    return Error::InvalidArgument;
  }
  if (!(request.fps > 0.0) || !(request.endSec > request.startSec)) {
    setLastError("tracking needs a positive fps and a non-empty range");
    return Error::InvalidArgument;
  }
  const int analysisWidth = std::max(64, request.analysisWidth);

  // Determinism (TRK-9). RANSAC draws from OpenCV's thread-local RNG, and its
  // parallel_for_ splits work by thread count — both would make the solved path
  // depend on the machine rather than the input.
  cv::setRNGSeed(20260830);
  const int savedThreads = cv::getNumThreads();
  cv::setNumThreads(1);
  struct ThreadGuard {
    int threads;
    ~ThreadGuard() { cv::setNumThreads(threads); }
  } guard{savedThreads};

  // Sample at the centre of each frame interval rather than its leading edge.
  // `startSec + i/fps` lands exactly on a frame boundary, where a double that
  // rounds a hair low asks the decoder for the previous frame; sampling mid-
  // interval puts the request comfortably inside the frame it means.
  const double sampleStep = 1.0 / request.fps;
  const auto sampleTime = [&](int index) {
    return request.startSec + (index + 0.5) * sampleStep;
  };

  DecodedFrame frame;
  Error err = extractFrameRgba(request.mediaPath, sampleTime(0), analysisWidth,
                               &frame);
  if (err != Error::None) return err;
  if (frame.width <= 0 || frame.height <= 0) {
    setLastError("tracking could not decode the first frame");
    return Error::MediaDecodeFailed;
  }

  cv::Mat previous = grayFrom(frame);

  // Everything below works in analysis pixels. The quad is authored and stored
  // in *source* pixels (TRK-7), and extractFrameRgba scales to analysisWidth
  // preserving aspect, so the ratio of decoded to source width converts between
  // them. The source width comes from the probe rather than a second decode at
  // native size, which would evict this thread's decoder session.
  double toAnalysis = 1.0;
  std::string probeJson;
  if (probeFile(request.mediaPath, &probeJson) == Error::None) {
    try {
      const auto probed = nlohmann::json::parse(probeJson);
      const double sourceWidth = probed.value("width", 0.0);
      if (sourceWidth > 0.0) toAnalysis = frame.width / sourceWidth;
    } catch (const std::exception&) {
      // A probe we cannot read leaves the 1:1 mapping, which is right whenever
      // the analysis width already matches the source.
    }
  }

  std::vector<cv::Point2f> quad = quadPoints(request.searchQuad, toAnalysis);
  if (!quadIsSane(quad, previous.size())) {
    setLastError("the tracked region is degenerate");
    return Error::InvalidArgument;
  }

  const double originalArea = std::abs(cv::contourArea(quad));

  std::vector<cv::Point2f> features = seedFeatures(previous, quad);
  size_t seedCount = features.size();

  const int sampleCount =
      std::max(1, static_cast<int>(std::floor((request.endSec - request.startSec) *
                                              request.fps)) + 1);

  std::vector<TrackSample> samples;
  samples.reserve(static_cast<size_t>(sampleCount));
  samples.push_back({quadFrom(quad, toAnalysis), 1.0});

  for (int i = 1; i < sampleCount; ++i) {
    if (onProgress && !onProgress(static_cast<double>(i) / sampleCount)) {
      return Error::Cancelled;
    }
    err = extractFrameRgba(request.mediaPath, sampleTime(i), analysisWidth,
                           &frame);
    if (err != Error::None) return err;
    const cv::Mat current = grayFrom(frame);

    double confidence = 0.0;
    if (features.size() >= static_cast<size_t>(kMinCorrespondences)) {
      std::vector<cv::Point2f> forward, backward;
      std::vector<uchar> statusFwd, statusBack;
      std::vector<float> errFwd, errBack;
      cv::calcOpticalFlowPyrLK(previous, current, features, forward, statusFwd,
                               errFwd);
      cv::calcOpticalFlowPyrLK(current, previous, forward, backward, statusBack,
                               errBack);

      std::vector<cv::Point2f> from, to;
      from.reserve(features.size());
      to.reserve(features.size());
      for (size_t k = 0; k < features.size(); ++k) {
        if (!statusFwd[k] || !statusBack[k]) continue;
        const double dx = backward[k].x - features[k].x;
        const double dy = backward[k].y - features[k].y;
        if (std::sqrt(dx * dx + dy * dy) > kMaxForwardBackwardError) continue;
        from.push_back(features[k]);
        to.push_back(forward[k]);
      }

      if (from.size() >= static_cast<size_t>(kMinCorrespondences)) {
        std::vector<uchar> inliers;
        const cv::Mat homography = cv::findHomography(
            from, to, cv::RANSAC, kRansacReprojectionPx, inliers);
        const int kept =
            static_cast<int>(std::count(inliers.begin(), inliers.end(), 1));
        if (!homography.empty() && kept >= kMinInliers) {
          std::vector<cv::Point2f> moved;
          cv::perspectiveTransform(quad, moved, homography);
          const double movedArea = std::abs(cv::contourArea(moved));
          const bool areaDrifted =
              originalArea > 0.0 &&
              (movedArea > originalArea * kMaxCumulativeAreaRatio ||
               movedArea < originalArea / kMaxCumulativeAreaRatio);
          if (!areaDrifted && quadIsSane(moved, current.size()) &&
              stepIsPlausible(quad, moved, current.size())) {
            quad = moved;
            confidence = clamp01(static_cast<double>(kept) / from.size());
          }
        }
        // Carry the surviving points forward; they are already where the next
        // frame expects them.
        features.clear();
        for (size_t k = 0; k < to.size(); ++k) features.push_back(to[k]);
      } else {
        features.clear();
      }
    }

    // TRK-8: a frame that could not be solved holds the last good pose and says
    // so, rather than letting the quad collapse or jump.
    samples.push_back({quadFrom(quad, toAnalysis), confidence});

    const bool starved =
        features.size() < static_cast<size_t>(kMinCorrespondences) ||
        (seedCount > 0 &&
         features.size() < static_cast<size_t>(seedCount * kReseedFraction));
    if (starved || confidence < kReseedConfidence) {
      features = seedFeatures(current, quad);
      seedCount = features.size();
    }
    previous = current;
  }

  if (onProgress && !onProgress(1.0)) return Error::Cancelled;

  quantizePath(&samples);
  const int stride = decimationStride(samples, kDecimationTolerancePx);
  if (stride > 1) {
    std::vector<TrackSample> thinned;
    thinned.reserve(samples.size() / stride + 1);
    for (size_t i = 0; i < samples.size(); i += stride) thinned.push_back(samples[i]);
    samples.swap(thinned);
  }

  out->samples = std::move(samples);
  out->fps = request.fps / stride;
  out->stride = stride;
  return Error::None;
}

#endif  // CC_HAS_TRACKING

}  // namespace cc
