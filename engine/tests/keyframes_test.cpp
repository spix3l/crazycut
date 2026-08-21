#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "graph/keyframes.h"

TEST(Keyframes, ReturnsStaticValueWithoutKeys) {
  nlohmann::json out;
  ASSERT_EQ(cc::evaluateParameter({{"static", 8.0}, {"keyframes", nlohmann::json::array()}},
                                  {1, 2}, &out), cc::Error::None);
  EXPECT_DOUBLE_EQ(out.get<double>(), 8.0);
}

TEST(Keyframes, InterpolatesNumericAndPointValues) {
  const nlohmann::json parameter = {
      {"static", {{"x", 0.0}, {"y", 0.0}}},
      {"keyframes", {{{"t", "0/1"}, {"v", {{"x", 0.0}, {"y", 10.0}}}, {"interp", "linear"}},
                     {{"t", "1/1"}, {"v", {{"x", 20.0}, {"y", 30.0}}}, {"interp", "linear"}}}}};
  nlohmann::json out;
  ASSERT_EQ(cc::evaluateParameter(parameter, {1, 2}, &out), cc::Error::None);
  EXPECT_DOUBLE_EQ(out["x"].get<double>(), 10.0);
  EXPECT_DOUBLE_EQ(out["y"].get<double>(), 20.0);
}

TEST(Keyframes, HoldsOutsideSpanAndSupportsHold) {
  const nlohmann::json parameter = {
      {"static", 0},
      {"keyframes", {{{"t", "1/1"}, {"v", 3}, {"interp", "hold"}},
                     {{"t", "2/1"}, {"v", 9}, {"interp", "linear"}}}}};
  nlohmann::json out;
  ASSERT_EQ(cc::evaluateParameter(parameter, {3, 2}, &out), cc::Error::None);
  EXPECT_DOUBLE_EQ(out.get<double>(), 3.0);
  ASSERT_EQ(cc::evaluateParameter(parameter, {4, 1}, &out), cc::Error::None);
  EXPECT_EQ(out, 9);
}
