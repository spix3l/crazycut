#pragma once

#include <map>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "core/result.h"

namespace cc {

constexpr int kMixSampleRate = 48000;  // AUD-14: locked at 48 kHz for v1

// Interleaved stereo float audio.
struct AudioBuffer {
  int sampleRate = kMixSampleRate;
  std::vector<float> samples;  // L,R,L,R…

  size_t frames() const { return samples.size() / 2; }
  void resizeFrames(size_t n) { samples.assign(n * 2, 0.f); }
};

// How the master bus finishes the mix.
struct MasterSettings {
  double gain = 1.0;           // linear master fader (AUD-10)
  bool limiter = true;         // AUD-11 safety brickwall
  double ceilingDb = -1.0;     // limiter ceiling in dBFS
};

// Mixes the audio of [document] over the window
// [startSec, startSec + durationSec) into stereo float at [sampleRate].
//
// This is the one audio path in the product: preview monitoring and export
// both call it, so what you hear is what you ship (arch §1). It applies, in
// order: per-clip gain/pan/fades (AUD-1/2/3), transition crossfades (AUD-9),
// track fader/pan with mute and solo (AUD-10), then master gain and the
// safety limiter (AUD-11).
//
// [mediaPaths] maps asset id → decode path. Assets that are missing, silent
// or undecodable contribute silence.
//
// [clipGains] optionally carries per-clip corrective linear gains keyed by
// clip id (AUD-16 export leveling); clips without an entry mix at unity.
Error mixTimeline(const nlohmann::json& document,
                  const std::map<std::string, std::string>& mediaPaths,
                  double startSec, double durationSec, int sampleRate,
                  const MasterSettings& master, AudioBuffer* out,
                  const std::map<std::string, double>* clipGains = nullptr);

// Reads master settings out of a document's `settings.master` object, falling
// back to the defaults above.
MasterSettings masterFromDocument(const nlohmann::json& document);

// --- Analysis ---------------------------------------------------------------

// Integrated loudness in LUFS per ITU-R BS.1770-4 (K-weighting, 400 ms blocks,
// absolute gate at −70 LUFS and the −10 LU relative gate). Returns -70.0 for
// silence, matching ffmpeg's floor (AUD-12).
double integratedLufs(const AudioBuffer& buffer);

// Sample peak in dBFS (−inf reported as −120).
double peakDb(const AudioBuffer& buffer);

// True peak in dBTP, estimated with 4× oversampling as BS.1770 prescribes.
double truePeakDb(const AudioBuffer& buffer);

// --- Export leveling (AUD-16) ----------------------------------------------

// Measures the integrated loudness (LUFS, same BS.1770-4 math as
// integratedLufs) of every audible clip's contribution to the window
// [startSec, startSec + durationSec), keyed by clip id. Levels are measured
// after the clip's own fader and track gain so deliberate balance choices
// survive leveling (AUD-16); fades, pans and crossfades do not count as
// level decisions and are excluded. Clips that are muted, soloed out,
// silent or shorter than one loudness block are omitted.
std::map<std::string, double> measureClipLoudnesses(
    const nlohmann::json& document,
    const std::map<std::string, std::string>& mediaPaths, double startSec,
    double durationSec, int sampleRate);

// Computes per-clip corrective linear gains that bring every measured clip to
// the median loudness of the set, clamped to ±[maxGainDb] dB around unity so
// a stray whisper cannot be blown up into noise. Unmeasured clips get no
// entry (they mix at unity).
std::map<std::string, double> computeLevelGains(
    const std::map<std::string, double>& clipLufs, double maxGainDb = 12.0);

}  // namespace cc
