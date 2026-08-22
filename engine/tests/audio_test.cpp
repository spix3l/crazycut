// Golden-audio suite (roadmap §2): fade curves by RMS, crossfade midpoint
// power, loudness math, and the preview==export guarantee for audio.

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "audio/decode.h"
#include "audio/mixer.h"

namespace {

using json = nlohmann::json;

// Writes a 48 kHz stereo 16-bit WAV of a steady sine so tests never depend on
// licensed media (roadmap: fixtures are generated programmatically).
std::string writeToneWav(const std::string& name, double seconds,
                         double frequency, double amplitude) {
  const int rate = 48000;
  const int channels = 2;
  const int frames = static_cast<int>(seconds * rate);
  const int dataBytes = frames * channels * 2;

  const std::filesystem::path path =
      std::filesystem::temp_directory_path() / ("cc_" + name + ".wav");
  std::ofstream out(path, std::ios::binary);

  auto u32 = [&](uint32_t v) { out.write(reinterpret_cast<char*>(&v), 4); };
  auto u16 = [&](uint16_t v) { out.write(reinterpret_cast<char*>(&v), 2); };

  out.write("RIFF", 4);
  u32(36 + dataBytes);
  out.write("WAVEfmt ", 8);
  u32(16);
  u16(1);                       // PCM
  u16(channels);
  u32(rate);
  u32(rate * channels * 2);     // byte rate
  u16(channels * 2);            // block align
  u16(16);                      // bits
  out.write("data", 4);
  u32(dataBytes);

  for (int i = 0; i < frames; ++i) {
    const double t = static_cast<double>(i) / rate;
    const auto s = static_cast<int16_t>(
        std::lround(std::sin(2 * M_PI * frequency * t) * amplitude * 32767));
    u16(static_cast<uint16_t>(s));
    u16(static_cast<uint16_t>(s));
  }
  return path.string();
}

json audioDoc(json clips, json transitions = json::array(),
              json tracks = json::array()) {
  if (tracks.empty()) {
    tracks = json::array({{{"id", "a1"},
                           {"kind", "audio"},
                           {"name", "A1"},
                           {"index", 0},
                           {"mute", false},
                           {"solo", false},
                           {"lock", false},
                           {"hidden", false},
                           {"height", 64}}});
  }
  return json{{"schema", "crazycut/project@1"},
              {"settings",
               {{"width", 1920},
                {"height", 1080},
                {"fps", "30/1"},
                {"audioSampleRate", 48000},
                {"background", "#000000"}}},
              {"tracks", std::move(tracks)},
              {"clips", std::move(clips)},
              {"transitions", std::move(transitions)},
              {"markers", json::array()}};
}

json audioClip(const std::string& id, double start, double duration,
               json extra = json::object()) {
  json clip = {{"id", id},
               {"trackId", "a1"},
               {"mediaId", "tone"},
               {"label", id},
               {"start", std::to_string(static_cast<int>(start * 1000)) + "/1000"},
               {"duration",
                std::to_string(static_cast<int>(duration * 1000)) + "/1000"},
               {"sourceIn", "0/1"},
               {"volume", 1.0},
               {"pan", 0.0},
               {"mute", false}};
  for (auto& [key, value] : extra.items()) clip[key] = value;
  return clip;
}

// RMS of a window of the mix, in dBFS.
double windowRmsDb(const cc::AudioBuffer& mix, double fromSec, double toSec) {
  const size_t a = static_cast<size_t>(fromSec * mix.sampleRate);
  const size_t b = std::min(mix.frames(), static_cast<size_t>(toSec * mix.sampleRate));
  if (b <= a) return -120.0;
  double sum = 0;
  for (size_t i = a; i < b; ++i) {
    const double l = mix.samples[i * 2];
    sum += l * l;
  }
  const double rms = std::sqrt(sum / static_cast<double>(b - a));
  return rms > 0 ? 20.0 * std::log10(rms) : -120.0;
}

class AudioMix : public ::testing::Test {
 protected:
  void SetUp() override {
    tone = writeToneWav("tone", 12.0, 440.0, 0.5);
    // A second, unrelated tone: crossfade power only sums predictably for
    // uncorrelated material, which is what real footage is.
    toneB = writeToneWav("toneb", 12.0, 703.0, 0.5);
    paths = {{"tone", tone}, {"toneB", toneB}};
  }
  void TearDown() override {
    std::error_code ec;
    std::filesystem::remove(tone, ec);
    std::filesystem::remove(toneB, ec);
  }
  std::string tone;
  std::string toneB;
  std::map<std::string, std::string> paths;
  cc::MasterSettings master;
};

TEST_F(AudioMix, DecodesRequestedRangeToStereo) {
  std::vector<float> pcm;
  ASSERT_EQ(cc::decodeStereoRange(tone, 1.0, 0.5, 48000, &pcm), cc::Error::None);
  EXPECT_EQ(pcm.size(), static_cast<size_t>(0.5 * 48000) * 2);
  double peak = 0;
  for (const float v : pcm) peak = std::max<double>(peak, std::fabs(v));
  EXPECT_NEAR(peak, 0.5, 0.02);
}

TEST_F(AudioMix, ClipGainAndMuteApply) {
  cc::AudioBuffer mix;
  ASSERT_EQ(cc::mixTimeline(audioDoc(json::array({audioClip("c", 0, 4)})), paths,
                            0, 4, 48000, master, &mix),
            cc::Error::None);
  const double full = windowRmsDb(mix, 1, 2);
  EXPECT_GT(full, -20.0);

  ASSERT_EQ(cc::mixTimeline(
                audioDoc(json::array({audioClip("c", 0, 4, {{"volume", 0.5}})})),
                paths, 0, 4, 48000, master, &mix),
            cc::Error::None);
  // Half gain is exactly −6.02 dB.
  EXPECT_NEAR(windowRmsDb(mix, 1, 2), full - 6.02, 0.1);

  ASSERT_EQ(cc::mixTimeline(
                audioDoc(json::array({audioClip("c", 0, 4, {{"mute", true}})})),
                paths, 0, 4, 48000, master, &mix),
            cc::Error::None);
  EXPECT_LT(windowRmsDb(mix, 1, 2), -100.0);
}

TEST_F(AudioMix, FadeCurvesFollowTheirShape) {
  // AUD acceptance 1: the fade the UI draws is the gain the mixer applies.
  const json clip = audioClip(
      "c", 0, 4,
      {{"fadeIn", {{"duration", "2/1"}, {"curve", "linear"}}}});
  cc::AudioBuffer mix;
  ASSERT_EQ(cc::mixTimeline(audioDoc(json::array({clip})), paths, 0, 4, 48000,
                            master, &mix),
            cc::Error::None);

  const double flat = windowRmsDb(mix, 3.0, 3.5);
  // Linear fade: at the halfway point gain is 0.5 → −6 dB from flat.
  EXPECT_NEAR(windowRmsDb(mix, 0.95, 1.05), flat - 6.02, 0.3);
  // A quarter in, gain is 0.25 → −12 dB.
  EXPECT_NEAR(windowRmsDb(mix, 0.45, 0.55), flat - 12.04, 0.4);
  // Silent at the very start.
  EXPECT_LT(windowRmsDb(mix, 0.0, 0.01), flat - 40.0);

  const json expo = audioClip(
      "c", 0, 4,
      {{"fadeIn", {{"duration", "2/1"}, {"curve", "exponential"}}}});
  ASSERT_EQ(cc::mixTimeline(audioDoc(json::array({expo})), paths, 0, 4, 48000,
                            master, &mix),
            cc::Error::None);
  // Exponential (p²): halfway is 0.25 → −12 dB, steeper than linear.
  EXPECT_NEAR(windowRmsDb(mix, 0.95, 1.05), flat - 12.04, 0.4);
}

TEST_F(AudioMix, CrossfadeMidpointHoldsPower) {
  // AUD-9 / TRA-8: an equal-power crossfade must not dip at the midpoint.
  // Two clips overlap for 1 s (3.5→4.5) with a transition between them.
  json clips = json::array(
      {audioClip("a", 0, 4.5),
       audioClip("b", 3.5, 4, {{"mediaId", "toneB"}})});
  json transitions = json::array({{{"id", "t1"},
                                   {"aClipId", "a"},
                                   {"bClipId", "b"},
                                   {"type", "crossDissolve"},
                                   {"duration", "1/1"}}});
  cc::AudioBuffer mix;
  ASSERT_EQ(cc::mixTimeline(audioDoc(clips, transitions), paths, 0, 7.5, 48000,
                            master, &mix),
            cc::Error::None);

  const double before = windowRmsDb(mix, 2.0, 3.0);   // clip A alone
  const double middle = windowRmsDb(mix, 3.95, 4.05); // crossfade midpoint
  const double after = windowRmsDb(mix, 5.0, 6.0);    // clip B alone
  EXPECT_NEAR(middle, before, 0.5) << "midpoint dips or peaks";
  EXPECT_NEAR(after, before, 0.5);
}

TEST_F(AudioMix, TrackFaderMuteAndSoloCompose) {
  json tracks = json::array(
      {{{"id", "a1"}, {"kind", "audio"}, {"name", "A1"}, {"index", 0},
        {"mute", false}, {"solo", false}, {"gain", 0.5}},
       {{"id", "a2"}, {"kind", "audio"}, {"name", "A2"}, {"index", 1},
        {"mute", false}, {"solo", false}}});
  cc::AudioBuffer mix;
  ASSERT_EQ(cc::mixTimeline(audioDoc(json::array({audioClip("c", 0, 4)}),
                                     json::array(), tracks),
                            paths, 0, 4, 48000, master, &mix),
            cc::Error::None);
  const double faded = windowRmsDb(mix, 1, 2);

  tracks[0]["gain"] = 1.0;
  ASSERT_EQ(cc::mixTimeline(audioDoc(json::array({audioClip("c", 0, 4)}),
                                     json::array(), tracks),
                            paths, 0, 4, 48000, master, &mix),
            cc::Error::None);
  EXPECT_NEAR(windowRmsDb(mix, 1, 2), faded + 6.02, 0.1);

  // Soloing the *other* track silences this one.
  tracks[1]["solo"] = true;
  ASSERT_EQ(cc::mixTimeline(audioDoc(json::array({audioClip("c", 0, 4)}),
                                     json::array(), tracks),
                            paths, 0, 4, 48000, master, &mix),
            cc::Error::None);
  EXPECT_LT(windowRmsDb(mix, 1, 2), -100.0);
}

TEST_F(AudioMix, PanIsUnityAtCentreAndSilencesTheFarSide) {
  cc::AudioBuffer mix;
  ASSERT_EQ(cc::mixTimeline(
                audioDoc(json::array({audioClip("c", 0, 4, {{"pan", 1.0}})})),
                paths, 0, 4, 48000, master, &mix),
            cc::Error::None);
  double peakL = 0, peakR = 0;
  for (size_t i = 0; i < mix.frames(); ++i) {
    peakL = std::max<double>(peakL, std::fabs(mix.samples[i * 2]));
    peakR = std::max<double>(peakR, std::fabs(mix.samples[i * 2 + 1]));
  }
  EXPECT_LT(peakL, 1e-6);
  EXPECT_NEAR(peakR, 0.5, 0.02);
}

TEST_F(AudioMix, MasterLimiterCapsAtCeiling) {
  // Four stacked full-scale clips would sum well past 0 dBFS.
  json tracks = json::array();
  json clips = json::array();
  for (int i = 0; i < 4; ++i) {
    const std::string id = "a" + std::to_string(i + 1);
    tracks.push_back({{"id", id}, {"kind", "audio"}, {"name", id},
                      {"index", i}, {"mute", false}, {"solo", false}});
    json clip = audioClip("c" + std::to_string(i), 0, 4);
    clip["trackId"] = id;
    clips.push_back(clip);
  }
  cc::MasterSettings limited;
  limited.limiter = true;
  limited.ceilingDb = -1.0;
  cc::AudioBuffer mix;
  ASSERT_EQ(cc::mixTimeline(audioDoc(clips, json::array(), tracks), paths, 0, 4,
                            48000, limited, &mix),
            cc::Error::None);
  EXPECT_LE(cc::peakDb(mix), -1.0 + 0.01);

  cc::MasterSettings open = limited;
  open.limiter = false;
  ASSERT_EQ(cc::mixTimeline(audioDoc(clips, json::array(), tracks), paths, 0, 4,
                            48000, open, &mix),
            cc::Error::None);
  EXPECT_GT(cc::peakDb(mix), 0.0) << "without the limiter this must clip";
}

TEST_F(AudioMix, IntegratedLoudnessMatchesReference) {
  // AUD acceptance 3: within ±0.5 LU of the reference measurement. A −20 dBFS
  // sine reads about −23.0 LUFS after K-weighting at 440 Hz.
  cc::AudioBuffer mix;
  ASSERT_EQ(cc::mixTimeline(audioDoc(json::array({audioClip("c", 0, 10)})),
                            paths, 0, 10, 48000, master, &mix),
            cc::Error::None);
  const double lufs = cc::integratedLufs(mix);
  // Reference: `ffmpeg -i tone.wav -filter_complex ebur128 -f null -` reports
  // I: -6.7 LUFS for this signal (0.5 amplitude sine, both channels).
  EXPECT_NEAR(lufs, -6.7, 0.5) << "measured " << lufs;

  // Halving the gain must move loudness by exactly 6 dB.
  cc::AudioBuffer quieter;
  ASSERT_EQ(cc::mixTimeline(
                audioDoc(json::array({audioClip("c", 0, 10, {{"volume", 0.5}})})),
                paths, 0, 10, 48000, master, &quieter),
            cc::Error::None);
  EXPECT_NEAR(cc::integratedLufs(quieter), lufs - 6.02, 0.1);

  cc::AudioBuffer silence;
  silence.resizeFrames(48000);
  EXPECT_DOUBLE_EQ(cc::integratedLufs(silence), -70.0);
}

TEST_F(AudioMix, WindowedMixMatchesFullMix) {
  // Preview mixes short windows while export mixes the whole sequence; the
  // samples must agree or monitoring would not represent the file.
  const json clip = audioClip(
      "c", 0, 6,
      {{"fadeIn", {{"duration", "1/1"}, {"curve", "scurve"}}},
       {{"fadeOut"}, {{"duration", "2/1"}, {"curve", "exponential"}}}});
  const json doc = audioDoc(json::array({clip}));

  cc::AudioBuffer whole;
  ASSERT_EQ(cc::mixTimeline(doc, paths, 0, 6, 48000, master, &whole),
            cc::Error::None);
  cc::AudioBuffer window;
  ASSERT_EQ(cc::mixTimeline(doc, paths, 2.0, 0.5, 48000, master, &window),
            cc::Error::None);

  const size_t offset = static_cast<size_t>(2.0 * 48000) * 2;
  ASSERT_GE(whole.samples.size(), offset + window.samples.size());
  double worst = 0;
  for (size_t i = 0; i < window.samples.size(); ++i) {
    worst = std::max<double>(
        worst, std::fabs(window.samples[i] - whole.samples[offset + i]));
  }
  // Decoder seek granularity allows a tiny difference, not an audible one.
  EXPECT_LT(worst, 0.01) << "windowed mix drifts from the full mix";
}

TEST_F(AudioMix, ScanPeakFindsClipLevel) {
  float peak = 0;
  ASSERT_EQ(cc::scanPeak(tone, 0, 5, 48000, &peak), cc::Error::None);
  EXPECT_NEAR(peak, 0.5, 0.02);
}

TEST_F(AudioMix, MissingAudioStreamMixesSilence) {
  std::map<std::string, std::string> missing{{"tone", "/nonexistent/file.wav"}};
  cc::AudioBuffer mix;
  ASSERT_EQ(cc::mixTimeline(audioDoc(json::array({audioClip("c", 0, 2)})),
                            missing, 0, 2, 48000, master, &mix),
            cc::Error::None);
  EXPECT_LT(cc::peakDb(mix), -100.0);
}

}  // namespace
