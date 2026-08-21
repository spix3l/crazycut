#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "media/prepare.h"

#ifndef CC_SOURCE_DIR
#define CC_SOURCE_DIR "."
#endif

namespace {
std::string fixturePath() {
  return std::string(CC_SOURCE_DIR) + "/../fixtures/media/sample.mp4";
}
bool fixtureExists() { std::ifstream file(fixturePath()); return file.good(); }
}

TEST(MediaPrepare, ComputesStableSha256) {
  const std::string path = std::string(CC_SOURCE_DIR) + "/build/hash-test.txt";
  { std::ofstream file(path, std::ios::binary); file << "abc"; }
  std::string hash;
  ASSERT_EQ(cc::hashFileSha256(path, &hash), cc::Error::None);
  EXPECT_EQ(hash, "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  std::remove(path.c_str());
}

TEST(MediaPrepare, ExtractsBoundedWaveformPeaks) {
  if (!fixtureExists()) GTEST_SKIP() << "fixture not generated";
  std::string text;
  ASSERT_EQ(cc::extractWaveform(fixturePath(), 100, &text), cc::Error::None);
  const auto waveform = nlohmann::json::parse(text);
  EXPECT_GT(waveform["sampleRate"].get<int>(), 0);
  EXPECT_GE(waveform["channels"].get<int>(), 1);
  EXPECT_GT(waveform["peaks"].size(), 900u);
  EXPECT_LT(waveform["peaks"].size(), 1100u);
  for (const auto& channel : waveform["peaks"][0]) {
    EXPECT_GE(channel[0].get<double>(), -1.0);
    EXPECT_LE(channel[1].get<double>(), 1.0);
  }
}
