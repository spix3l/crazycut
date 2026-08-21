#pragma once

#include <string>

namespace cc {

enum class LogLevel { Debug, Info, Warning, Error };

void logMessage(LogLevel level, const char* file, int line, const std::string& message);

#define CC_LOG_DEBUG(msg) ::cc::logMessage(::cc::LogLevel::Debug, __FILE_NAME__, __LINE__, (msg))
#define CC_LOG_INFO(msg) ::cc::logMessage(::cc::LogLevel::Info, __FILE_NAME__, __LINE__, (msg))
#define CC_LOG_WARN(msg) ::cc::logMessage(::cc::LogLevel::Warning, __FILE_NAME__, __LINE__, (msg))
#define CC_LOG_ERROR(msg) ::cc::logMessage(::cc::LogLevel::Error, __FILE_NAME__, __LINE__, (msg))

}  // namespace cc
