#pragma once

#include <array>
#include <functional>
#include <string>
#include <vector>

#include "core/result.h"

namespace cc {

/// A quad in TL/TR/BR/BL order, flattened. Source pixels of the tracked media.
using TrackQuad = std::array<double, 8>;

struct TrackSample {
  TrackQuad quad{};
  /// Inlier ratio of the frame's homography fit, 0..1. A frame that could not
  /// be solved holds the previous pose and reports 0 (TRK-8).
  double confidence = 0.0;
};

struct TrackRequest {
  std::string mediaPath;
  /// The region the user drew, in source pixels.
  TrackQuad searchQuad{};
  double startSec = 0.0;
  double endSec = 0.0;
  /// Sample rate to solve at. Usually the media's own frame rate.
  double fps = 0.0;
  /// Frames are decoded down to this width for analysis; solved quads are
  /// scaled back to full source pixels before they are returned (TRK-7).
  int analysisWidth = 720;
};

struct TrackResult {
  std::vector<TrackSample> samples;
  /// Rate the samples are stored at, after decimation. Never above
  /// `request.fps`; samples are addressed by index at this rate.
  double fps = 0.0;
  /// Whole-number decimation applied, so callers holding `request.fps` as a
  /// rational can divide it exactly rather than re-deriving a rate from
  /// [fps]'s float.
  int stride = 1;
};

/// Reports progress in [0,1] and returns false to ask for cancellation.
using TrackProgress = std::function<bool(double)>;

/// True when the engine was built with area-tracking support. The worker
/// reports a clear message rather than a crash when it was not (TRK-12).
bool trackingAvailable();

/// Solves the motion of [request.searchQuad] across the requested range.
///
/// Deterministic: the same media, quad, range, analysis width and algorithm
/// version give bit-identical output (TRK-9). Cancellation returns
/// `Error::Cancelled` with nothing written.
Error solveRegion(const TrackRequest& request, TrackResult* out,
                  const TrackProgress& onProgress);

/// Largest whole-number decimation of [samples] whose linear reconstruction
/// stays within [tolerancePx] of every dropped sample, capped at [maxStride].
///
/// Uniform decimation rather than a variable-spaced simplification, because the
/// stored path is addressed by index at a fixed rate (02-data-model.md
/// §5 Tracker) — dropping samples unevenly would break that. A locked-off shot
/// still collapses to a handful of samples, which is the point (TRK-14).
int decimationStride(const std::vector<TrackSample>& samples, double tolerancePx,
                     int maxStride = 30);

/// Rounds every coordinate to three decimals, the stored precision (TRK-14).
/// Applied before the result leaves the solver so what is measured in tests is
/// what lands in the document.
void quantizePath(std::vector<TrackSample>* samples);

}  // namespace cc
