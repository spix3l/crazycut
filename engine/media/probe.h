#pragma once

#include <string>

#include "core/result.h"

namespace cc {

Error probeFile(const std::string& path, std::string* outJson);

}  // namespace cc
