#pragma once

#include <functional>
#include <map>
#include <optional>
#include <set>
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

// Everything about a document that the renderer would otherwise rederive on
// every single frame: which video tracks are visible and in what order, each
// track's clips with their rational times already parsed out of the JSON, and
// the transition and clip-id lookups.
//
// Rebuilding this per frame is what a plain renderFrame(document, ...) call
// does, and for a preview scrub that is the right trade. An export renders the
// same document thousands of times, so it builds one index up front and hands
// it to every frame.
//
// The index borrows the document: it stores pointers into it, so it must not
// outlive the document and the document must not be mutated while it is alive.
class RenderIndex {
 public:
  explicit RenderIndex(const nlohmann::json& document);

  struct ClipSpan {
    const nlohmann::json* clip = nullptr;
    RationalTime start;
    RationalTime end;
  };
  struct Track {
    std::string id;
    int index = 0;
    bool hidden = false;
    std::vector<ClipSpan> clips;  // document order, as the renderer sees them
  };

  const nlohmann::json& document() const { return *document_; }
  const std::vector<Track>& videoTracks() const { return videoTracks_; }
  // The clip covering [time] on [track]: the last one in document order, which
  // is how an overlap bound to a transition resolves.
  const nlohmann::json* clipAt(const Track& track, const RationalTime& time) const;
  const nlohmann::json* clipById(const std::string& id) const;
  // The transition this clip is the A (outgoing) or B (incoming) side of.
  const nlohmann::json* transitionAsA(const std::string& clipId) const;
  const nlohmann::json* transitionAsB(const std::string& clipId) const;

 private:
  const nlohmann::json* document_ = nullptr;
  std::vector<Track> videoTracks_;
  std::map<std::string, const nlohmann::json*> clipsById_;
  std::map<std::string, const nlohmann::json*> transitionsAsA_;
  std::map<std::string, const nlohmann::json*> transitionsAsB_;
};

// A frame that needs no compositing at all: one visible clip, nothing applied
// to it, its pixels filling the canvas. Reported by passthroughFrameAt().
struct PassthroughFrame {
  std::string path;             // the clip's media file
  double sourceSeconds = 0.0;   // where in it this frame lives
};

// The ids of clips that can skip compositing for their entire length, so a
// caller that only wants pixels to encode can decode each frame and use it as
// it is instead of paying for the RGBA round trip: decode → convert to RGBA →
// composite onto a canvas → convert back. That round trip is most of the cost
// of an export, and an ordinary cut between two full-frame clips needs none of
// it.
//
// A clip is out if the compositor has real work to do on it anywhere: another
// visible layer overlaps it, it is in a transition, it is text, it carries
// effects or an exposure correction, it has a non-normal blend or partial
// opacity, or it has any transform that is not a fixed identity.
//
// The decision is per clip and never per frame, because the two paths do not
// produce identical pixels: compositing resamples chroma through RGB and
// passthrough keeps the source's. Alternating between them inside one clip
// would show as the picture shifting the moment a title appeared over it, so
// a clip that needs compositing for one frame is composited for all of them,
// and the only place the two paths ever meet is a cut.
//
// Membership does not by itself mean a frame can be used: the caller must
// still confirm the decoded frame fills the canvas and is not rotated. Those
// need the decoded frame, which this call deliberately does not touch.
std::set<std::string> passthroughClips(
    const RenderIndex& index, int width, int height,
    const std::function<std::optional<ClipSource>(const std::string& assetId)>&
        resolve,
    const std::map<std::string, double>* exposureStops = nullptr);

// Where in its media the clip covering [time] sits, for a clip that
// passthroughClips() approved. Returns nothing when this frame is not a lone
// visible clip from that set.
std::optional<PassthroughFrame> passthroughFrameAt(
    const RenderIndex& index, const RationalTime& time,
    const std::set<std::string>& eligible,
    const std::function<std::optional<ClipSource>(const std::string& assetId)>&
        resolve);

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
//
// [exposureStops] optionally carries per-clip exposure corrections in stops
// keyed by clip id (EXP-15 export exposure matching), applied after the
// clip's own effects stack. Clips without an entry are untouched.
Error renderFrame(const nlohmann::json& document, const RationalTime& time,
                  int width, int height,
                  const std::function<std::optional<ClipSource>(
                      const std::string& assetId)>& resolve,
                  RgbaSurface* out,
                  const std::map<std::string, double>* exposureStops = nullptr);

// Same render against a prebuilt index, for callers that draw many frames of
// one unchanging document.
Error renderFrame(const RenderIndex& index, const RationalTime& time, int width,
                  int height,
                  const std::function<std::optional<ClipSource>(
                      const std::string& assetId)>& resolve,
                  RgbaSurface* out,
                  const std::map<std::string, double>* exposureStops = nullptr);

// Convenience: renders against a map of asset id → path.
Error renderFrame(const nlohmann::json& document, const RationalTime& time,
                  int width, int height,
                  const std::map<std::string, std::string>& assetPaths,
                  RgbaSurface* out,
                  const std::map<std::string, double>* exposureStops = nullptr);

// --- Export exposure matching (EXP-15) --------------------------------------

// Samples [samplesPerClip] frames across each visible video clip's trimmed
// source range within the sequence window [startSec, endSec) and returns the
// mean linear-light Rec.709 luma (0…1) per clip id. Clips without decodable
// media, and frames that decode black, are omitted.
std::map<std::string, double> measureClipLuma(
    const nlohmann::json& document,
    const std::map<std::string, std::string>& assetPaths, double startSec,
    double endSec, int samplesPerClip = 6);

// Computes per-clip exposure corrections in stops that pull every measured
// clip's luma toward the median of the set, clamped to ±[maxStops] so the
// correction stays gentle and grading intent survives. Unmeasured clips get
// no entry.
std::map<std::string, double> computeExposureStops(
    const std::map<std::string, double>& clipLuma, double maxStops = 0.5);

}  // namespace cc
