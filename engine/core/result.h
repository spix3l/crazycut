#pragma once

#include <cstdint>
#include <string>

namespace cc {

enum class Error : int32_t {
  None = 0,
  InvalidArgument = 1,
  IoError = 2,
  // Cooperative cancellation, not a failure: callers report it as "stopped"
  // rather than surfacing an error (AI-13).
  Cancelled = 3,
  MediaOpenFailed = 10,
  MediaDecodeFailed = 11,
  MediaNoStream = 12,
  EncodeFailed = 13,
  MuxFailed = 14,
  InternalError = 100,
};

const char* errorName(Error error);

void setLastError(const std::string& message);
const char* lastError();

}  // namespace cc
