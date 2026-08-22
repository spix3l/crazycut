#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "model/project.h"

namespace {
nlohmann::json minimalProject() {
  return {{"schema", "crazycut/project@1"},
          {"id", "p1"},
          {"settings", {{"width", 1920}, {"height", 1080}, {"fps", "30000/1001"},
                        {"audioSampleRate", 48000}}},
          {"media", {{{"id", "m1"}, {"type", "video"}, {"duration", "10/1"}}}},
          {"tracks", {{{"id", "v1"}, {"kind", "video"}, {"index", 0}},
                      {{"id", "a1"}, {"kind", "audio"}, {"index", 0}}}},
          {"clips", {{{"id", "c1"}, {"trackId", "v1"}, {"mediaId", "m1"},
                      {"start", "0/1"}, {"duration", "5/1"}, {"sourceIn", "0/1"},
                      {"speed", {{"num", 1}, {"den", 1}}}, {"effects", nlohmann::json::array()}}}},
          {"transitions", nlohmann::json::array()}, {"markers", nlohmann::json::array()}};
}
}

TEST(Project, LoadsAndReportsDuration) {
  cc::ProjectSnapshot snapshot;
  ASSERT_EQ(snapshot.load(minimalProject().dump()), cc::Error::None);
  EXPECT_EQ(snapshot.clipCount(), 1u);
  EXPECT_EQ(snapshot.duration(), (cc::RationalTime{5, 1}));
  EXPECT_TRUE(snapshot.issues().empty());
}

TEST(Project, AcceptsVerboseAndCanonicalizesTimes) {
  auto project = minimalProject();
  project["clips"][0]["start"] = {{"n", 2}, {"d", 4}};
  cc::ProjectSnapshot snapshot;
  ASSERT_EQ(snapshot.load(project.dump()), cc::Error::None);
  EXPECT_EQ(snapshot.document()["clips"][0]["start"], "1/2");
  EXPECT_EQ(snapshot.duration(), (cc::RationalTime{11, 2}));
}

TEST(Project, RepairsDanglingClipsWithoutDiscardingUnknownFields) {
  auto project = minimalProject();
  project["futureField"] = {{"kept", true}};
  project["clips"].push_back({{"id", "bad"}, {"trackId", "missing"},
                              {"mediaId", "m1"}, {"start", "0/1"},
                              {"duration", "1/1"}});
  cc::ProjectSnapshot snapshot;
  ASSERT_EQ(snapshot.load(project.dump(), true), cc::Error::None);
  EXPECT_EQ(snapshot.clipCount(), 1u);
  EXPECT_TRUE(snapshot.document()["futureField"]["kept"]);
  ASSERT_FALSE(snapshot.issues().empty());
}

TEST(Project, RejectsNewerMajorSchema) {
  auto project = minimalProject();
  project["schema"] = "crazycut/project@2";
  cc::ProjectSnapshot snapshot;
  EXPECT_EQ(snapshot.load(project.dump()), cc::Error::InvalidArgument);
}

TEST(Project, DetectsAudioOverlap) {
  auto project = minimalProject();
  project["clips"][0]["trackId"] = "a1";
  auto second = project["clips"][0];
  second["id"] = "c2";
  second["start"] = "4/1";
  project["clips"].push_back(second);
  cc::ProjectSnapshot snapshot;
  ASSERT_EQ(snapshot.load(project.dump()), cc::Error::None);
  bool found = false;
  for (const auto& issue : snapshot.issues()) found |= issue.code == "audio_overlap";
  EXPECT_TRUE(found);
}

TEST(Project, AllowsVideoOverlapOnlyWhenTransitionMatchesExactly) {
  auto project = minimalProject();
  auto second = project["clips"][0];
  second["id"] = "c2";
  second["start"] = "4/1";
  second["sourceIn"] = "1/1";
  project["clips"].push_back(second);
  project["transitions"].push_back({{"id", "tr1"}, {"aClipId", "c1"},
                                     {"bClipId", "c2"}, {"type", "crossDissolve"},
                                     {"duration", "1/1"}});
  cc::ProjectSnapshot snapshot;
  ASSERT_EQ(snapshot.load(project.dump()), cc::Error::None);
  for (const auto& issue : snapshot.issues()) {
    EXPECT_NE(issue.code, "video_overlap");
    EXPECT_NE(issue.code, "invalid_transition");
  }
}

// Regression: a split at the playhead leaves both halves on the microsecond
// grid. Their times used to overflow a 32-bit denominator, so validation
// decided the right-hand half ran past the end of its media and dropped it
// from the render graph — the clip went black and silent.
TEST(Project, KeepsClipsSplitOnTheMicrosecondGrid) {
  auto project = minimalProject();
  project["clips"][0]["duration"] = "2733333/1000000";
  project["clips"].push_back({{"id", "c2"},
                              {"trackId", "v1"},
                              {"mediaId", "m1"},
                              {"start", "2733333/1000000"},
                              {"duration", "2266667/1000000"},
                              {"sourceIn", "2733333/1000000"},
                              {"speed", {{"num", 1}, {"den", 1}}},
                              {"effects", nlohmann::json::array()}});
  cc::ProjectSnapshot snapshot;
  ASSERT_EQ(snapshot.load(project.dump(), true), cc::Error::None);
  EXPECT_EQ(snapshot.clipCount(), 2u);
  EXPECT_TRUE(snapshot.issues().empty());
  EXPECT_EQ(snapshot.duration(), (cc::RationalTime{5, 1}));
}
