#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

#include <gtest/gtest.h>

#include "media/frame.h"
#include "media/probe.h"

#ifndef CC_SOURCE_DIR
#define CC_SOURCE_DIR "."
#endif

namespace {

std::string fixturePath() {
  if (const char* env = std::getenv("CC_FIXTURE")) {
    return env;
  }
  return std::string(CC_SOURCE_DIR) + "/../fixtures/media/sample.mp4";
}

std::string gifFixturePath() {
  return std::string(CC_SOURCE_DIR) + "/../fixtures/media/animated.gif";
}

bool fixtureExists() {
  std::ifstream f(fixturePath());
  return f.good();
}

bool gifFixtureExists() {
  std::ifstream f(gifFixturePath());
  return f.good();
}

}  // namespace

TEST(Probe, ReportsMetadataForFixture) {
  if (!fixtureExists()) {
    GTEST_SKIP() << "fixture not generated (run tools/make-fixture.sh)";
  }
  std::string json;
  ASSERT_EQ(cc::probeFile(fixturePath(), &json), cc::Error::None);
  EXPECT_NE(json.find("\"width\":640"), std::string::npos);
  EXPECT_NE(json.find("\"height\":360"), std::string::npos);
  EXPECT_NE(json.find("\"type\":\"video\""), std::string::npos);
  EXPECT_NE(json.find("h264"), std::string::npos);
}

TEST(Probe, FailsCleanlyOnMissingFile) {
  std::string json;
  EXPECT_EQ(cc::probeFile("/nonexistent/nope.mp4", &json), cc::Error::MediaOpenFailed);
  EXPECT_STREQ("open failed: No such file or directory", cc::lastError());
}

TEST(Probe, ClassifiesPipeDemuxedStillAsImage) {
  const auto path = std::filesystem::temp_directory_path() /
                    "crazycut-probe-static-image.ppm";
  {
    std::ofstream image(path, std::ios::binary | std::ios::trunc);
    ASSERT_TRUE(image.good());
    image << "P6\n2 2\n255\n";
    const unsigned char pixels[] = {
        255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255,
    };
    image.write(reinterpret_cast<const char*>(pixels), sizeof(pixels));
  }

  std::string json;
  EXPECT_EQ(cc::probeFile(path.string(), &json), cc::Error::None);
  EXPECT_NE(json.find("\"type\":\"image\""), std::string::npos);
  std::error_code ignored;
  std::filesystem::remove(path, ignored);
}

TEST(Probe, ClassifiesAnimatedGifAsTimedVisualMedia) {
  if (!gifFixtureExists()) {
    GTEST_SKIP() << "GIF fixture not generated (run tools/make-fixture.sh)";
  }
  std::string json;
  ASSERT_EQ(cc::probeFile(gifFixturePath(), &json), cc::Error::None);
  EXPECT_NE(json.find("\"type\":\"video\""), std::string::npos);
  EXPECT_NE(json.find("\"codec\":\"gif\""), std::string::npos);
  EXPECT_NE(json.find("\"durationSeconds\":2.0"), std::string::npos);
  EXPECT_NE(json.find("\"audio\":null"), std::string::npos);
}

TEST(Frame, ExtractsRgbaAtRequestedWidth) {
  if (!fixtureExists()) {
    GTEST_SKIP() << "fixture not generated";
  }
  cc::DecodedFrame frame;
  ASSERT_EQ(cc::extractFrameRgba(fixturePath(), 1.0, 320, &frame), cc::Error::None);
  EXPECT_EQ(frame.width, 320);
  EXPECT_EQ(static_cast<size_t>(frame.width) * frame.height * 4, frame.rgba.size());

  size_t colored = 0;
  for (size_t i = 0; i < frame.rgba.size(); i += 4) {
    const uint8_t r = frame.rgba[i];
    const uint8_t g = frame.rgba[i + 1];
    const uint8_t b = frame.rgba[i + 2];
    if (r > 30 || g > 30 || b > 30) ++colored;
  }
  EXPECT_GT(colored, frame.rgba.size() / 16);
}

TEST(Frame, ThumbnailProducesJpegBytes) {
  if (!fixtureExists()) {
    GTEST_SKIP() << "fixture not generated";
  }
  std::vector<uint8_t> jpeg;
  ASSERT_EQ(cc::extractThumbnailJpeg(fixturePath(), 0.5, 480, &jpeg), cc::Error::None);
  ASSERT_GE(jpeg.size(), 1000u);
  EXPECT_EQ(jpeg[0], 0xFF);
  EXPECT_EQ(jpeg[1], 0xD8);
}

TEST(Frame, AnimatedGifDecodesFrameAtRequestedTime) {
  if (!gifFixtureExists()) {
    GTEST_SKIP() << "GIF fixture not generated (run tools/make-fixture.sh)";
  }
  cc::DecodedFrame first;
  cc::DecodedFrame second;
  ASSERT_EQ(cc::extractFrameRgba(gifFixturePath(), 0.25, 16, &first),
            cc::Error::None);
  ASSERT_EQ(cc::extractFrameRgba(gifFixturePath(), 1.25, 16, &second),
            cc::Error::None);
  ASSERT_EQ(first.width, second.width);
  ASSERT_EQ(first.height, second.height);
  EXPECT_NE(first.rgba, second.rgba);
}

// Regression: playing to the end of a clip and staying there wiped the frame
// the decoder was holding. avcodec_receive_frame unrefs its destination before
// it reports EAGAIN/EOF, so the drain path handed back a zero-sized frame and
// the compositor drew the offline slate — the preview blinked between picture
// and checkerboard for the rest of the clip.
TEST(Frame, HoldsTheLastFrameAtEndOfFile) {
  if (!fixtureExists()) {
    GTEST_SKIP() << "fixture not generated";
  }
  cc::DecodedFrame frame;
  // Walk into the tail of the file and keep asking past its end.
  for (double t = 9.0; t <= 10.5; t += 1.0 / 30.0) {
    ASSERT_EQ(cc::extractFrameRgba(fixturePath(), t, 320, &frame), cc::Error::None)
        << "at t=" << t;
    EXPECT_GT(frame.width, 0) << "at t=" << t;
    EXPECT_GT(frame.height, 0) << "at t=" << t;
    EXPECT_FALSE(frame.rgba.empty()) << "at t=" << t;
  }
}
