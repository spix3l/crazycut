#pragma once

#include <cstdint>
#include <optional>
#include <string>

namespace cc {

struct RationalTime {
  int64_t num = 0;
  int32_t den = 1;

  static RationalTime fromSeconds(double seconds);
  static RationalTime fromFrames(int64_t frames, const RationalTime& fps);

  RationalTime normalized() const;
  double toSeconds() const;
  std::string toString() const;

  bool isValid() const { return den > 0; }
};

RationalTime operator+(const RationalTime& a, const RationalTime& b);
RationalTime operator-(const RationalTime& a, const RationalTime& b);
bool operator==(const RationalTime& a, const RationalTime& b);
bool operator!=(const RationalTime& a, const RationalTime& b);
bool operator<(const RationalTime& a, const RationalTime& b);
bool operator<=(const RationalTime& a, const RationalTime& b);
bool operator>(const RationalTime& a, const RationalTime& b);
bool operator>=(const RationalTime& a, const RationalTime& b);

std::optional<RationalTime> parseRationalTime(const std::string& text);

}  // namespace cc
