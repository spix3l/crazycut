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
