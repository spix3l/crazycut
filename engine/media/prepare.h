#pragma once

#include <string>

#include "core/result.h"

namespace cc {

Error hashFileSha256(const std::string& path, std::string* outHash);
Error extractWaveform(const std::string& path, int peaksPerSecond,
                      std::string* outJson);

}  // namespace cc
