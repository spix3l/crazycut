#include "audio/mixer.h"

#include <algorithm>
#include <cmath>

#include "audio/decode.h"
#include "core/log.h"
#include "core/time.h"
#include "model/project.h"

namespace cc {
namespace {

using json = nlohmann::json;
constexpr double kPi = 3.14159265358979323846;

double clampd(double v, double lo, double hi) {
  return std::min(std::max(v, lo), hi);
}

// One clip's contribution to the mix, resolved from JSON once.
struct ClipSpan {
  std::string id;
  std::string path;
  double startSec = 0;
  double durationSec = 0;
  double sourceInSec = 0;
  double speed = 1.0;
  double volume = 1.0;
  double pan = 0.0;
  double fadeInSec = 0.0;
  std::string fadeInCurve = "linear";
  double fadeOutSec = 0.0;
  std::string fadeOutCurve = "exponential";
  double trackGain = 1.0;
  double trackPan = 0.0;
  // AUD-16: corrective gain from export loudness leveling, folded in with
  // the fader gains. Unity unless the caller passes measured gains.
  double analysisGain = 1.0;
};

// AUD-2 curves. `p` runs 0→1 across the fade, 0 = silent end.
double curveGain(double p, const std::string& curve) {
  p = clampd(p, 0.0, 1.0);
  if (curve == "exponential") return p * p;
  if (curve == "scurve") return p * p * (3.0 - 2.0 * p);
  return p;  // linear
}

double fadeGain(const ClipSpan& span, double localSec) {
  double g = 1.0;
  if (span.fadeInSec > 0.0 && localSec < span.fadeInSec) {
    g *= curveGain(localSec / span.fadeInSec, span.fadeInCurve);
  }
  if (span.fadeOutSec > 0.0 &&
      localSec > span.durationSec - span.fadeOutSec) {
    const double remaining = std::max(0.0, span.durationSec - localSec);
    g *= curveGain(remaining / span.fadeOutSec, span.fadeOutCurve);
  }
  return clampd(g, 0.0, 1.0);
}

// nlohmann's value() returns a *copy*; iterating it and keeping pointers into
// the elements dangles as soon as the temporary dies. Always bind to the real
// array.
const json& arrayField(const json& owner, const char* key) {
  static const json kEmpty = json::array();
  const auto it = owner.find(key);
  if (it == owner.end() || !it->is_array()) return kEmpty;
  return *it;
}

double jsonSeconds(const json& owner, const char* key, double fallback) {
  if (!owner.contains(key)) return fallback;
  if (const auto t = parseJsonTime(owner[key])) return t->toSeconds();
  return fallback;
}

// K-weighting for BS.1770: a shelving filter followed by a high-pass, both
// as biquads at 48 kHz (coefficients from the specification).
struct Biquad {
  double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
  double x1 = 0, x2 = 0, y1 = 0, y2 = 0;

  double process(double x) {
    const double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1;
    x1 = x;
    y2 = y1;
    y1 = y;
    return y;
  }
};

Biquad shelvingFilter(double rate) {
  // Stage 1 high-shelf, +4 dB above ~1.5 kHz.
  const double f0 = 1681.974450955533;
  const double G = 3.999843853973347;
  const double Q = 0.7071752369554196;
  const double K = std::tan(kPi * f0 / rate);
  const double Vh = std::pow(10.0, G / 20.0);
  const double Vb = std::pow(Vh, 0.4996667741545416);
  const double denom = 1.0 + K / Q + K * K;
  Biquad f;
  f.b0 = (Vh + Vb * K / Q + K * K) / denom;
  f.b1 = 2.0 * (K * K - Vh) / denom;
  f.b2 = (Vh - Vb * K / Q + K * K) / denom;
  f.a1 = 2.0 * (K * K - 1.0) / denom;
  f.a2 = (1.0 - K / Q + K * K) / denom;
  return f;
}

Biquad highpassFilter(double rate) {
  // Stage 2 RLB high-pass at ~38 Hz.
  const double f0 = 38.13547087602444;
  const double Q = 0.5003270373238773;
  const double K = std::tan(kPi * f0 / rate);
  Biquad f;
  f.b0 = 1.0;
  f.b1 = -2.0;
  f.b2 = 1.0;
  f.a1 = 2.0 * (K * K - 1.0) / (1.0 + K / Q + K * K);
  f.a2 = (1.0 - K / Q + K * K) / (1.0 + K / Q + K * K);
  return f;
}

}  // namespace

// Resolves every audible clip overlapping [startSec, windowEnd) into spans.
// Shared by mixTimeline and measureClipLoudnesses so leveling measures exactly
// what mixing plays (solo wins over mute across the whole sequence, AUD-10).
std::vector<ClipSpan> collectSpans(const json& document,
                                   const std::map<std::string, std::string>& mediaPaths,
                                   double startSec, double windowEnd) {
  std::vector<ClipSpan> spans;
  bool anySolo = false;
  for (const auto& track : arrayField(document, "tracks")) {
    if (track.is_object() && track.value("solo", false)) anySolo = true;
  }

  for (const auto& track : arrayField(document, "tracks")) {
    if (!track.is_object()) continue;
    if (anySolo ? !track.value("solo", false) : track.value("mute", false)) {
      continue;
    }
    const std::string trackId = track.value("id", "");
    const double trackGain = clampd(track.value("gain", 1.0), 0.0, 4.0);
    const double trackPan = clampd(track.value("pan", 0.0), -1.0, 1.0);

    for (const auto& clip : arrayField(document, "clips")) {
      if (!clip.is_object() || clip.value("trackId", "") != trackId) continue;
      if (clip.value("mute", false)) continue;
      const std::string mediaId = clip.value("mediaId", "");
      if (mediaId.empty()) continue;  // text clips are silent
      const auto path = mediaPaths.find(mediaId);
      if (path == mediaPaths.end()) continue;

      ClipSpan span;
      span.id = clip.value("id", "");
      span.path = path->second;
      span.startSec = jsonSeconds(clip, "start", -1);
      span.durationSec = jsonSeconds(clip, "duration", 0);
      if (span.startSec < 0 || span.durationSec <= 0) continue;
      // Skip clips outside the requested window entirely.
      if (span.startSec >= windowEnd ||
          span.startSec + span.durationSec <= startSec) {
        continue;
      }
      span.sourceInSec = jsonSeconds(clip, "sourceIn", 0);
      if (clip.contains("speed") && clip["speed"].is_object()) {
        span.speed = static_cast<double>(clip["speed"].value("num", 1)) /
                     std::max(1, clip["speed"].value("den", 1));
      }
      span.volume = clampd(clip.value("volume", 1.0), 0.0, 4.0);
      span.pan = clampd(clip.value("pan", 0.0), -1.0, 1.0);
      if (clip.contains("fadeIn") && clip["fadeIn"].is_object()) {
        span.fadeInSec = jsonSeconds(clip["fadeIn"], "duration", 0);
        span.fadeInCurve = clip["fadeIn"].value("curve", "linear");
      }
      if (clip.contains("fadeOut") && clip["fadeOut"].is_object()) {
        span.fadeOutSec = jsonSeconds(clip["fadeOut"], "duration", 0);
        span.fadeOutCurve = clip["fadeOut"].value("curve", "exponential");
      }
      span.trackGain = trackGain;
      span.trackPan = trackPan;
      spans.push_back(std::move(span));
    }
  }
  return spans;
}

MasterSettings masterFromDocument(const json& document) {
  MasterSettings m;
  if (!document.contains("settings") || !document["settings"].is_object()) {
    return m;
  }
  const json& settings = document["settings"];
  if (!settings.contains("master") || !settings["master"].is_object()) return m;
  const json& master = settings["master"];
  m.gain = clampd(master.value("gain", 1.0), 0.0, 4.0);
  m.limiter = master.value("limiter", true);
  m.ceilingDb = clampd(master.value("ceilingDb", -1.0), -24.0, 0.0);
  return m;
}

Error mixTimeline(const json& document,
                  const std::map<std::string, std::string>& mediaPaths,
                  double startSec, double durationSec, int sampleRate,
                  const MasterSettings& master, AudioBuffer* out,
                  const std::map<std::string, double>* clipGains) {
  if (!out || sampleRate <= 0 || durationSec < 0) {
    setLastError("mixTimeline: invalid arguments");
    return Error::InvalidArgument;
  }
  startSec = std::max(0.0, startSec);
  out->sampleRate = sampleRate;
  const size_t frames =
      static_cast<size_t>(std::ceil(durationSec * sampleRate));
  out->resizeFrames(frames);
  if (frames == 0) return Error::None;

  const double windowEnd = startSec + durationSec;

  std::vector<ClipSpan> spans =
      collectSpans(document, mediaPaths, startSec, windowEnd);
  if (clipGains) {
    for (auto& span : spans) {
      const auto it = clipGains->find(span.id);
      if (it != clipGains->end()) {
        span.analysisGain = clampd(it->second, 0.0, 4.0);
      }
    }
  }

  // Transition overlaps get an equal-power crossfade (AUD-9/TRA-8): within the
  // overlap each side is weighted by cos/sin of the progress angle, which
  // keeps summed power constant instead of dipping in the middle the way two
  // linear fades would.
  struct Crossfade {
    std::string aId, bId;
    double start = 0, end = 0;
  };
  std::vector<Crossfade> crossfades;
  for (const auto& tr : arrayField(document, "transitions")) {
    if (!tr.is_object()) continue;
    const std::string aId = tr.value("aClipId", "");
    const std::string bId = tr.value("bClipId", "");
    const json *a = nullptr, *b = nullptr;
    for (const auto& clip : arrayField(document, "clips")) {
      if (!clip.is_object()) continue;
      if (clip.value("id", "") == aId) a = &clip;
      if (clip.value("id", "") == bId) b = &clip;
    }
    if (!a || !b) continue;
    const double aStart = jsonSeconds(*a, "start", 0);
    const double aEnd = aStart + jsonSeconds(*a, "duration", 0);
    const double bStart = jsonSeconds(*b, "start", 0);
    const double bEnd = bStart + jsonSeconds(*b, "duration", 0);
    const double ovStart = std::max(aStart, bStart);
    const double ovEnd = std::min(aEnd, bEnd);
    if (ovEnd > ovStart) crossfades.push_back({aId, bId, ovStart, ovEnd});
  }

  std::vector<float> pcm;
  for (const auto& span : spans) {
    // Only the part of the clip inside the window is decoded.
    const double clipWindowStart = std::max(startSec, span.startSec);
    const double clipWindowEnd =
        std::min(windowEnd, span.startSec + span.durationSec);
    const double take = clipWindowEnd - clipWindowStart;
    if (take <= 0) continue;

    const double localStart = clipWindowStart - span.startSec;
    const double sourceStart = span.sourceInSec + localStart * span.speed;
    // Varispeed resamples by stepping the source faster/slower (AUD-4); the
    // pitch-preserving path is a v1.5 item, documented in the audio spec.
    const double sourceTake = take * span.speed;
    if (decodeStereoRange(span.path, sourceStart, sourceTake, sampleRate,
                          &pcm) != Error::None) {
      continue;
    }
    const size_t srcFrames = pcm.size() / 2;
    const size_t dstOffset =
        static_cast<size_t>(std::llround((clipWindowStart - startSec) *
                                         sampleRate));
    const size_t dstCount =
        static_cast<size_t>(std::llround(take * sampleRate));

    // Balance law (AUD-3): centre is unity and panning attenuates the far
    // side. Sources are already stereo here, so a constant-power law would
    // quietly drop every centred clip by 3 dB.
    auto balance = [](double pan, double* l, double* r) {
      *l = pan <= 0 ? 1.0 : 1.0 - pan;
      *r = pan >= 0 ? 1.0 : 1.0 + pan;
    };
    double clipPanL, clipPanR, trackPanL, trackPanR;
    balance(span.pan, &clipPanL, &clipPanR);
    balance(span.trackPan, &trackPanL, &trackPanR);

    for (size_t i = 0; i < dstCount; ++i) {
      const size_t o = dstOffset + i;
      if (o >= frames) break;
      const double tSeq = startSec + static_cast<double>(o) / sampleRate;
      const double local = tSeq - span.startSec;

      // Source sample for this output sample (nearest; speed 1 is exact).
      const size_t srcIndex = static_cast<size_t>(
          std::llround((local - localStart) * span.speed * sampleRate));
      if (srcIndex >= srcFrames) break;

      double gain = span.volume * span.trackGain * span.analysisGain *
                    fadeGain(span, local);
      for (const auto& xf : crossfades) {
        if (tSeq < xf.start || tSeq >= xf.end) continue;
        if (span.id != xf.aId && span.id != xf.bId) continue;
        const double p = (tSeq - xf.start) / std::max(1e-9, xf.end - xf.start);
        gain *= span.id == xf.aId ? std::cos(p * kPi / 2.0)
                                  : std::sin(p * kPi / 2.0);
      }
      if (gain <= 0.0) continue;

      out->samples[o * 2] +=
          static_cast<float>(pcm[srcIndex * 2] * gain * clipPanL * trackPanL);
      out->samples[o * 2 + 1] += static_cast<float>(pcm[srcIndex * 2 + 1] *
                                                    gain * clipPanR * trackPanR);
    }
  }

  // Master fader, then the brickwall. The limiter is a hard clip at the
  // ceiling: it exists to stop accidental overs reaching the file, not to be
  // a mastering tool (AUD-11).
  const float ceiling =
      static_cast<float>(std::pow(10.0, master.ceilingDb / 20.0));
  const float gain = static_cast<float>(master.gain);
  for (float& sample : out->samples) {
    sample *= gain;
    if (master.limiter) {
      sample = std::min(std::max(sample, -ceiling), ceiling);
    }
  }
  return Error::None;
}

double integratedLufs(const AudioBuffer& buffer) {
  const size_t frames = buffer.frames();
  const double rate = buffer.sampleRate;
  if (frames == 0 || rate <= 0) return -70.0;

  Biquad shelfL = shelvingFilter(rate), shelfR = shelvingFilter(rate);
  Biquad hpL = highpassFilter(rate), hpR = highpassFilter(rate);

  // 400 ms blocks with 75% overlap, as the standard specifies.
  const size_t blockFrames = static_cast<size_t>(0.4 * rate);
  const size_t stepFrames = blockFrames / 4;
  if (blockFrames == 0 || frames < blockFrames) return -70.0;

  std::vector<double> squaredL(frames), squaredR(frames);
  for (size_t i = 0; i < frames; ++i) {
    const double l = hpL.process(shelfL.process(buffer.samples[i * 2]));
    const double r = hpR.process(shelfR.process(buffer.samples[i * 2 + 1]));
    squaredL[i] = l * l;
    squaredR[i] = r * r;
  }

  std::vector<double> blockLoudness;
  std::vector<double> blockPower;
  for (size_t start = 0; start + blockFrames <= frames; start += stepFrames) {
    double sumL = 0, sumR = 0;
    for (size_t i = start; i < start + blockFrames; ++i) {
      sumL += squaredL[i];
      sumR += squaredR[i];
    }
    const double meanL = sumL / blockFrames;
    const double meanR = sumR / blockFrames;
    const double power = meanL + meanR;  // both channels weighted 1.0
    if (power <= 0) continue;
    const double loudness = -0.691 + 10.0 * std::log10(power);
    if (loudness < -70.0) continue;  // absolute gate
    blockLoudness.push_back(loudness);
    blockPower.push_back(power);
  }
  if (blockPower.empty()) return -70.0;

  double ungatedPower = 0;
  for (const double p : blockPower) ungatedPower += p;
  const double ungated =
      -0.691 + 10.0 * std::log10(ungatedPower / blockPower.size());
  const double relativeGate = ungated - 10.0;

  double gatedPower = 0;
  size_t counted = 0;
  for (size_t i = 0; i < blockPower.size(); ++i) {
    if (blockLoudness[i] <= relativeGate) continue;
    gatedPower += blockPower[i];
    ++counted;
  }
  if (counted == 0) return -70.0;
  return -0.691 + 10.0 * std::log10(gatedPower / counted);
}

double peakDb(const AudioBuffer& buffer) {
  float peak = 0.f;
  for (const float s : buffer.samples) peak = std::max(peak, std::fabs(s));
  if (peak <= 0.f) return -120.0;
  return 20.0 * std::log10(peak);
}

double truePeakDb(const AudioBuffer& buffer) {
  // 4× linear oversampling: cheap, and within a few tenths of a dB of a
  // polyphase reconstruction for the overshoot detection we need.
  const size_t frames = buffer.frames();
  if (frames < 2) return peakDb(buffer);
  double peak = 0.0;
  for (int ch = 0; ch < 2; ++ch) {
    for (size_t i = 0; i + 1 < frames; ++i) {
      const double a = buffer.samples[i * 2 + ch];
      const double b = buffer.samples[(i + 1) * 2 + ch];
      for (int k = 0; k < 4; ++k) {
        const double t = k / 4.0;
        peak = std::max(peak, std::fabs(a + (b - a) * t));
      }
    }
  }
  if (peak <= 0.0) return -120.0;
  return 20.0 * std::log10(peak);
}

std::map<std::string, double> measureClipLoudnesses(
    const json& document, const std::map<std::string, std::string>& mediaPaths,
    double startSec, double durationSec, int sampleRate) {
  std::map<std::string, double> out;
  if (sampleRate <= 0 || durationSec < 0) return out;
  startSec = std::max(0.0, startSec);
  const double windowEnd = startSec + durationSec;

  std::vector<float> pcm;
  for (const ClipSpan& span :
       collectSpans(document, mediaPaths, startSec, windowEnd)) {
    // Level what the export actually plays: the clip's intersection with the
    // window, at its own speed — not the whole source file.
    const double clipWindowStart = std::max(startSec, span.startSec);
    const double clipWindowEnd =
        std::min(windowEnd, span.startSec + span.durationSec);
    const double take = clipWindowEnd - clipWindowStart;
    if (take <= 0) continue;
    const double localStart = clipWindowStart - span.startSec;
    if (decodeStereoRange(span.path,
                          span.sourceInSec + localStart * span.speed,
                          take * span.speed, sampleRate,
                          &pcm) != Error::None) {
      continue;
    }
    AudioBuffer buf;
    buf.sampleRate = sampleRate;
    buf.samples = std::move(pcm);
    // Measure what the faders deliver (volume × track gain), not the raw
    // source: a deliberate fader choice is intent, and leveling must never
    // undo it — it evens out the material itself. Fades are excluded on
    // purpose: they shape edges, they are not a level decision.
    double lufs = integratedLufs(buf);
    const double preGain = span.volume * span.trackGain;
    if (lufs > -70.0 && preGain > 0.0 && preGain != 1.0) {
      lufs += 20.0 * std::log10(preGain);
    }
    // integratedLufs reports -70 for silence and sub-block material; those
    // clips have no meaningful level to match, so they stay at unity.
    if (lufs > -70.0) out[span.id] = lufs;
  }
  return out;
}

std::map<std::string, double> computeLevelGains(
    const std::map<std::string, double>& clipLufs, double maxGainDb) {
  std::map<std::string, double> out;
  std::vector<double> values;
  for (const auto& [id, lufs] : clipLufs) {
    (void)id;
    if (lufs > -70.0) values.push_back(lufs);
  }
  if (values.empty()) return out;
  std::sort(values.begin(), values.end());
  // Median: one wild outlier should not become the reference every other
  // clip is pulled toward.
  const double median =
      values.size() % 2 == 1
          ? values[values.size() / 2]
          : 0.5 * (values[values.size() / 2 - 1] + values[values.size() / 2]);
  maxGainDb = std::max(0.0, maxGainDb);
  for (const auto& [id, lufs] : clipLufs) {
    if (lufs <= -70.0) continue;
    const double gainDb = clampd(median - lufs, -maxGainDb, maxGainDb);
    out[id] = std::pow(10.0, gainDb / 20.0);
  }
  return out;
}

}  // namespace cc
