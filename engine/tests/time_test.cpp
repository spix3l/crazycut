#include "core/time.h"

#include <gtest/gtest.h>

using cc::RationalTime;

TEST(RationalTime, Normalizes) {
  const RationalTime t{500, 1000};
  EXPECT_EQ(t.normalized().num, 1);
  EXPECT_EQ(t.normalized().den, 2);
}

TEST(RationalTime, NegativeDenBecomesPositive) {
  const RationalTime t{1, -30};
  EXPECT_EQ(t.normalized().num, -1);
  EXPECT_EQ(t.normalized().den, 30);
}

TEST(RationalTime, NtscFramesAreExact) {
  const auto fps = RationalTime{30000, 1001};
  const RationalTime frame5 = RationalTime::fromFrames(5, fps);
  EXPECT_EQ(frame5.num * 30000, 5005 * frame5.den);
  EXPECT_DOUBLE_EQ(frame5.toSeconds(), 5 * 1001.0 / 30000.0);
}

TEST(RationalTime, AdditionKeepsPrecision) {
  const auto a = RationalTime{1001, 30000};
  const RationalTime sum = a + a + a;
  EXPECT_EQ(sum.num, 1001);
  EXPECT_EQ(sum.den, 10000);
}

TEST(RationalTime, Comparison) {
  const RationalTime half{1, 2};
  const RationalTime quarter{250, 1000};
  const RationalTime fiftyHundredths{50, 100};
  EXPECT_TRUE(quarter < half);
  EXPECT_TRUE(half > quarter);
  EXPECT_TRUE(half == fiftyHundredths);
}

TEST(RationalTime, FromSecondsRoundsToMicrosecond) {
  const RationalTime t = RationalTime::fromSeconds(0.3336670034);
  EXPECT_NEAR(t.toSeconds(), 0.333667, 1e-9);
}

TEST(RationalTime, ParseRoundTrip) {
  const auto parsed = cc::parseRationalTime("450/3");
  ASSERT_TRUE(parsed.has_value());
  EXPECT_EQ(parsed->num, 150);
  EXPECT_EQ(parsed->den, 1);
  EXPECT_EQ(parsed->toString(), "150/1");
}

TEST(RationalTime, ParseRejectsInvalid) {
  EXPECT_FALSE(cc::parseRationalTime("abc").has_value());
  EXPECT_FALSE(cc::parseRationalTime("1/0").has_value());
  EXPECT_FALSE(cc::parseRationalTime("/2").has_value());
}

// Regression: splitting at the playhead leaves clips on the microsecond grid.
// A 32-bit denominator overflowed on start+duration, so the renderer decided
// no clip covered the frame and the second half of every split went black.
TEST(RationalTime, MicrosecondGridAdditionIsExact) {
  const auto start = *cc::parseRationalTime("2733333/1000000");
  const auto duration = *cc::parseRationalTime("7266667/1000000");
  const RationalTime end = start + duration;
  EXPECT_EQ(end.num, 10);
  EXPECT_EQ(end.den, 1);
  const auto mid = *cc::parseRationalTime("5000000/1000000");
  EXPECT_TRUE(mid >= start && mid < end);
}

TEST(RationalTime, SubtractionOnMicrosecondGridIsExact) {
  const auto time = *cc::parseRationalTime("4500001/1000000");
  const auto start = *cc::parseRationalTime("2733333/1000000");
  EXPECT_NEAR((time - start).toSeconds(), 1.766668, 1e-12);
}

TEST(RationalTime, LargeDenominatorsSurviveParsing) {
  const auto parsed = cc::parseRationalTime("3000000001/3000000000");
  ASSERT_TRUE(parsed.has_value());
  EXPECT_EQ(parsed->den, 3000000000);
  EXPECT_TRUE(*parsed > (RationalTime{1, 1}));
}

TEST(RationalTime, MultiplicationAppliesSpeed) {
  const auto duration = *cc::parseRationalTime("7266667/1000000");
  const RationalTime doubled = duration * RationalTime{2, 1};
  EXPECT_NEAR(doubled.toSeconds(), 14.533334, 1e-12);
  const RationalTime half = duration * RationalTime{1, 2};
  EXPECT_NEAR(half.toSeconds(), 3.6333335, 1e-12);
}
