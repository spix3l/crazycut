#include <chrono>
#include <thread>

#include <gtest/gtest.h>

#include "playback/player.h"

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

bool fixtureExists() {
  FILE* f = fopen(fixturePath().c_str(), "rb");
  if (!f) return false;
  fclose(f);
  return true;
}

}  // namespace

TEST(Playback, PlaysAndAdvancesClock) {
  if (!fixtureExists()) {
    GTEST_SKIP() << "fixture not generated (run tools/make-fixture.sh)";
  }
  cc::PlaybackSession* session = cc::PlaybackSession::create(fixturePath(), 640);
  ASSERT_NE(session, nullptr);
  EXPECT_NEAR(session->durationSeconds(), 10.0, 0.2);

  EXPECT_EQ(session->start(), cc::Error::None);
  EXPECT_TRUE(session->isPlaying());

  std::this_thread::sleep_for(std::chrono::milliseconds(900));
  const double pos = session->positionSeconds();
  EXPECT_GT(pos, 0.3);
  EXPECT_LT(pos, 3.0);

  int w = 0;
  int h = 0;
  const uint8_t* frame = session->lockFrame(&w, &h);
  if (frame) {
    EXPECT_GT(w, 0);
    EXPECT_GT(h, 0);
    session->unlockFrame();
  }

  session->pause();
  const double pausedAt = session->positionSeconds();
  std::this_thread::sleep_for(std::chrono::milliseconds(250));
  EXPECT_NEAR(session->positionSeconds(), pausedAt, 0.05);

  EXPECT_EQ(session->seek(5.0), cc::Error::None);
  std::this_thread::sleep_for(std::chrono::milliseconds(400));
  EXPECT_NEAR(session->positionSeconds(), 5.4, 1.2);

  delete session;
}

TEST(Playback, RejectsMissingFile) {
  EXPECT_EQ(cc::PlaybackSession::create("/nonexistent/nope.mp4", 320), nullptr);
}
