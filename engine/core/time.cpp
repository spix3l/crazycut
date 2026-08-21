#include "core/time.h"

#include <cmath>
#include <cstdlib>

namespace cc {

namespace {

int64_t gcd(int64_t a, int64_t b) {
  while (b != 0) {
    int64_t t = b;
    b = a % b;
    a = t;
  }
  return a < 0 ? -a : a;
}

}  // namespace

RationalTime RationalTime::fromSeconds(double seconds) {
  const double scaled = std::round(seconds * 1'000'000.0);
  return RationalTime{static_cast<int64_t>(scaled), 1'000'000}.normalized();
}

RationalTime RationalTime::fromFrames(int64_t frames, const RationalTime& fps) {
  return RationalTime{frames * fps.den, static_cast<int32_t>(fps.num)}.normalized();
}

RationalTime RationalTime::normalized() const {
  if (den == 0) {
    return RationalTime{num, 1};
  }
  int32_t d = den;
  int64_t n = num;
  if (d < 0) {
    d = -d;
    n = -n;
  }
  const int64_t g = gcd(n, static_cast<int64_t>(d));
  if (g > 1) {
    n /= g;
    d = static_cast<int32_t>(static_cast<int64_t>(d) / g);
  }
  return RationalTime{n, d};
}

double RationalTime::toSeconds() const {
  return isValid() ? static_cast<double>(num) / static_cast<double>(den) : 0.0;
}

std::string RationalTime::toString() const {
  return std::to_string(num) + "/" + std::to_string(den);
}

RationalTime operator+(const RationalTime& a, const RationalTime& b) {
  return RationalTime{a.num * b.den + b.num * a.den, a.den * b.den}.normalized();
}

RationalTime operator-(const RationalTime& a, const RationalTime& b) {
  return RationalTime{a.num * b.den - b.num * a.den, a.den * b.den}.normalized();
}

bool operator==(const RationalTime& a, const RationalTime& b) {
  return a.num * static_cast<int64_t>(b.den) == b.num * static_cast<int64_t>(a.den);
}

bool operator!=(const RationalTime& a, const RationalTime& b) { return !(a == b); }

bool operator<(const RationalTime& a, const RationalTime& b) {
  return a.num * static_cast<int64_t>(b.den) < b.num * static_cast<int64_t>(a.den);
}

bool operator<=(const RationalTime& a, const RationalTime& b) { return !(b < a); }

bool operator>(const RationalTime& a, const RationalTime& b) { return b < a; }

bool operator>=(const RationalTime& a, const RationalTime& b) { return !(a < b); }

std::optional<RationalTime> parseRationalTime(const std::string& text) {
  const auto slash = text.find('/');
  if (slash == std::string::npos) {
    return std::nullopt;
  }
  char* endN = nullptr;
  char* endD = nullptr;
  const int64_t n = std::strtoll(text.c_str(), &endN, 10);
  const long long d = std::strtoll(text.c_str() + slash + 1, &endD, 10);
  if (endN == text.c_str() || endD == text.c_str() + slash + 1 || d <= 0) {
    return std::nullopt;
  }
  return RationalTime{n, static_cast<int32_t>(d)}.normalized();
}

}  // namespace cc
