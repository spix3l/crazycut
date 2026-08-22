#include "core/time.h"

#include <cmath>
#include <cstdlib>
#include <limits>

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

#if defined(__SIZEOF_INT128__)
using wide = __int128;
#else
using wide = long double;
#endif

constexpr int64_t kMaxInt64 = std::numeric_limits<int64_t>::max();

bool fitsInt64(wide v) {
#if defined(__SIZEOF_INT128__)
  return v <= static_cast<wide>(kMaxInt64) && v >= -static_cast<wide>(kMaxInt64);
#else
  return std::fabsl(v) <= static_cast<wide>(kMaxInt64);
#endif
}

// Builds a normalized time from a 128-bit numerator/denominator pair. Times
// that cannot be represented exactly fall back to microsecond precision rather
// than wrapping around — a rounded frame beats a garbage one.
RationalTime fromWide(wide n, wide d, double approximateSeconds) {
  if (d == 0) return RationalTime{0, 1};
  if (d < 0) {
    n = -n;
    d = -d;
  }
#if defined(__SIZEOF_INT128__)
  // Reduce first: the exact result usually fits even when the raw product does
  // not (adding two 1/1'000'000-grid times is the common case).
  wide a = n < 0 ? -n : n;
  wide b = d;
  while (b != 0) {
    const wide t = b;
    b = a % b;
    a = t;
  }
  if (a > 1) {
    n /= a;
    d /= a;
  }
#endif
  if (!fitsInt64(n) || !fitsInt64(d)) {
    return RationalTime::fromSeconds(approximateSeconds);
  }
  return RationalTime{static_cast<int64_t>(n), static_cast<int64_t>(d)}.normalized();
}

// a ± b over a gcd-reduced common denominator.
RationalTime addSigned(const RationalTime& a, const RationalTime& b, int sign) {
  if (a.den <= 0 || b.den <= 0) return RationalTime{0, 1};
  const int64_t g = gcd(a.den, b.den);
  const wide ad = a.den / g;
  const wide bd = b.den / g;
  const wide num = static_cast<wide>(a.num) * bd +
                   static_cast<wide>(sign) * static_cast<wide>(b.num) * ad;
  const wide den = static_cast<wide>(a.den) * bd;
  return fromWide(num, den, a.toSeconds() + sign * b.toSeconds());
}

}  // namespace

RationalTime RationalTime::fromSeconds(double seconds) {
  const double scaled = std::round(seconds * 1'000'000.0);
  return RationalTime{static_cast<int64_t>(scaled), 1'000'000}.normalized();
}

RationalTime RationalTime::fromFrames(int64_t frames, const RationalTime& fps) {
  if (fps.num == 0) return RationalTime{0, 1};
  return RationalTime{frames * fps.den, fps.num}.normalized();
}

RationalTime RationalTime::normalized() const {
  if (den == 0) {
    return RationalTime{num, 1};
  }
  int64_t d = den;
  int64_t n = num;
  if (d < 0) {
    d = -d;
    n = -n;
  }
  const int64_t g = gcd(n, d);
  if (g > 1) {
    n /= g;
    d /= g;
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
  return addSigned(a, b, 1);
}

RationalTime operator-(const RationalTime& a, const RationalTime& b) {
  return addSigned(a, b, -1);
}

RationalTime operator*(const RationalTime& a, const RationalTime& b) {
  if (a.den <= 0 || b.den <= 0) return RationalTime{0, 1};
  // Cross-reduce before multiplying so ordinary products never grow wide.
  const int64_t g1 = gcd(a.num, b.den);
  const int64_t g2 = gcd(b.num, a.den);
  const wide num = static_cast<wide>(g1 ? a.num / g1 : a.num) *
                   static_cast<wide>(g2 ? b.num / g2 : b.num);
  const wide den = static_cast<wide>(g2 ? a.den / g2 : a.den) *
                   static_cast<wide>(g1 ? b.den / g1 : b.den);
  return fromWide(num, den, a.toSeconds() * b.toSeconds());
}

namespace {

// Cross-multiplied comparison in 128 bits: cross products of two microsecond
// times exceed int64 well before either time does.
int compareRt(const RationalTime& a, const RationalTime& b) {
  const wide l = static_cast<wide>(a.num) * static_cast<wide>(b.den);
  const wide r = static_cast<wide>(b.num) * static_cast<wide>(a.den);
  if (l < r) return -1;
  return l > r ? 1 : 0;
}

}  // namespace

bool operator==(const RationalTime& a, const RationalTime& b) {
  return compareRt(a, b) == 0;
}

bool operator!=(const RationalTime& a, const RationalTime& b) { return !(a == b); }

bool operator<(const RationalTime& a, const RationalTime& b) {
  return compareRt(a, b) < 0;
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
  const int64_t d = std::strtoll(text.c_str() + slash + 1, &endD, 10);
  if (endN == text.c_str() || endD == text.c_str() + slash + 1 || d <= 0) {
    return std::nullopt;
  }
  return RationalTime{n, d}.normalized();
}

}  // namespace cc
