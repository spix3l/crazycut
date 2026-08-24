#pragma once

#include <string>

namespace cc {

enum class LogLevel { Debug, Info, Warning, Error };

void logMessage(LogLevel level, const char* file, int line, const std::string& message);

#ifdef __FILE_NAME__
#define CC_LOG_FILE __FILE_NAME__
#else
#define CC_LOG_FILE __FILE__
#endif

#define CC_LOG_DEBUG(msg) ::cc::logMessage(::cc::LogLevel::Debug, CC_LOG_FILE, __LINE__, (msg))
#define CC_LOG_INFO(msg) ::cc::logMessage(::cc::LogLevel::Info, CC_LOG_FILE, __LINE__, (msg))
#define CC_LOG_WARN(msg) ::cc::logMessage(::cc::LogLevel::Warning, CC_LOG_FILE, __LINE__, (msg))
#define CC_LOG_ERROR(msg) ::cc::logMessage(::cc::LogLevel::Error, CC_LOG_FILE, __LINE__, (msg))

}  // namespace cc
