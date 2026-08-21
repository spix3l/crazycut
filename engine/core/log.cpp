#include "core/log.h"

#include <chrono>
#include <cstdio>
#include <ctime>

namespace cc {

namespace {

const char* levelName(LogLevel level) {
  switch (level) {
    case LogLevel::Debug: return "DEBUG";
    case LogLevel::Info: return "INFO";
    case LogLevel::Warning: return "WARN";
    case LogLevel::Error: return "ERROR";
  }
  return "LOG";
}

void localTime(std::time_t t, std::tm* out) {
#ifdef _WIN32
  localtime_s(out, &t);
#else
  localtime_r(&t, out);
#endif
}

}  // namespace

void logMessage(LogLevel level, const char* file, int line, const std::string& message) {
  const auto now = std::chrono::system_clock::now();
  std::time_t t = std::chrono::system_clock::to_time_t(now);
  std::tm tm{};
  localTime(t, &tm);
  char stamp[32];
  std::strftime(stamp, sizeof(stamp), "%H:%M:%S", &tm);
  std::fprintf(stderr, "%s [%s] %s:%d %s\n", stamp, levelName(level), file, line,
               message.c_str());
}

}  // namespace cc
