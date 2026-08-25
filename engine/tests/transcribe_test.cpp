#include <cstdlib>
#include <fstream>
#include <string>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "media/transcribe.h"

#ifndef CC_SOURCE_DIR
#define CC_SOURCE_DIR "."
#endif

namespace {

std::string fixturePath() {
  return std::string(CC_SOURCE_DIR) + "/../fixtures/media/sample.mp4";
}

bool fixtureExists() {
  std::ifstream file(fixturePath());
  return file.good();
}

// A full recognition pass needs a ~150 MB model, which does not belong in a
// unit-test run. Point CC_WHISPER_MODEL at a downloaded ggml model to exercise
// the real path locally; without it, the tests below still cover argument
// validation, the decode stage, cancellation and the failure messages.
const char* modelFromEnv() { return std::getenv("CC_WHISPER_MODEL"); }

}  // namespace

TEST(Transcribe, ReportsWhetherItWasBuiltIn) {
  // The worker relies on this to say "not built with transcription support"
  // rather than failing obscurely (AI-19).
#ifdef CC_HAS_WHISPER
  EXPECT_TRUE(cc::transcriptionAvailable());
#else
  EXPECT_FALSE(cc::transcriptionAvailable());
#endif
}

TEST(Transcribe, RejectsEmptyArguments) {
  std::string out;
  EXPECT_EQ(cc::transcribe("", "model.bin", "en", 2, &out, nullptr),
            cc::Error::InvalidArgument);
  EXPECT_EQ(cc::transcribe("media.mp4", "model.bin", "en", 2, nullptr, nullptr),
            cc::Error::InvalidArgument);
}

TEST(Transcribe, RejectsAMissingModelPath) {
  if (!cc::transcriptionAvailable()) GTEST_SKIP() << "built without whisper";
  std::string out;
  EXPECT_EQ(cc::transcribe("media.mp4", "", "en", 2, &out, nullptr),
            cc::Error::InvalidArgument);
}

TEST(Transcribe, FailsClearlyOnUnopenableMedia) {
  if (!cc::transcriptionAvailable()) GTEST_SKIP() << "built without whisper";
  std::string out;
  const cc::Error error = cc::transcribe("/nonexistent/clip.mp4", "model.bin",
                                         "en", 2, &out, nullptr);
  EXPECT_EQ(error, cc::Error::MediaOpenFailed);
  EXPECT_NE(std::string(cc::lastError()).find("transcription"),
            std::string::npos);
}

TEST(Transcribe, DecodesAudioAndReportsProgressBeforeRecognition) {
  if (!cc::transcriptionAvailable()) GTEST_SKIP() << "built without whisper";
  if (!fixtureExists()) GTEST_SKIP() << "fixture missing; run tools/make-fixture.sh";

  // Cancelling at the first progress tick proves the decode stage ran and that
  // cancellation is honoured before the expensive recognition pass starts.
  double lastSeen = -1;
  std::string out;
  const cc::Error error =
      cc::transcribe(fixturePath(), "/nonexistent/model.bin", "en", 2, &out,
                     [&](double fraction) {
                       lastSeen = fraction;
                       return false;  // ask to stop
                     });

  EXPECT_GE(lastSeen, 0.0);
  // Either it stopped when asked, or it got as far as failing to load the
  // model — both mean the audio decoded. What it must not do is claim success.
  EXPECT_TRUE(error == cc::Error::Cancelled || error == cc::Error::IoError);
  EXPECT_TRUE(out.empty());
}

TEST(Transcribe, ProducesMonotonicTimedSegments) {
  if (!cc::transcriptionAvailable()) GTEST_SKIP() << "built without whisper";
  const char* model = modelFromEnv();
  if (!model) GTEST_SKIP() << "set CC_WHISPER_MODEL to run the full pass";
  if (!fixtureExists()) GTEST_SKIP() << "fixture missing";

  std::string out;
  double lastProgress = -1;
  ASSERT_EQ(cc::transcribe(fixturePath(), model, "en", 4, &out,
                           [&](double fraction) {
                             EXPECT_GE(fraction, lastProgress);
                             lastProgress = fraction;
                             return true;
                           }),
            cc::Error::None);

  const auto json = nlohmann::json::parse(out);
  EXPECT_EQ(json["version"], 1);
  EXPECT_GT(json["durationSeconds"].get<double>(), 0.0);

  double previousEnd = -1;
  for (const auto& segment : json["segments"]) {
    const double start = segment["start"].get<double>();
    const double end = segment["end"].get<double>();
    EXPECT_GE(start, previousEnd - 1e-6) << "segments must not run backwards";
    EXPECT_GE(end, start);
    EXPECT_FALSE(segment["text"].get<std::string>().empty());
    previousEnd = end;
  }
}
