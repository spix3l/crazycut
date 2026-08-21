#include "core/result.h"

namespace cc {

namespace {
thread_local std::string t_lastError;
}

const char* errorName(Error error) {
  switch (error) {
    case Error::None: return "None";
    case Error::InvalidArgument: return "InvalidArgument";
    case Error::IoError: return "IoError";
    case Error::MediaOpenFailed: return "MediaOpenFailed";
    case Error::MediaDecodeFailed: return "MediaDecodeFailed";
    case Error::MediaNoStream: return "MediaNoStream";
    case Error::EncodeFailed: return "EncodeFailed";
    case Error::MuxFailed: return "MuxFailed";
    case Error::InternalError: return "InternalError";
  }
  return "Unknown";
}

void setLastError(const std::string& message) { t_lastError = message; }

const char* lastError() { return t_lastError.c_str(); }

}  // namespace cc
