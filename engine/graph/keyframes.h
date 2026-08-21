#pragma once

#include <string>

#include <nlohmann/json.hpp>

#include "core/result.h"
#include "core/time.h"

namespace cc {

// Evaluates a parameter object containing {static, keyframes}. Numeric values,
// points and colors are interpolated recursively. Enums/strings use hold.
Error evaluateParameter(const nlohmann::json& parameter, const RationalTime& time,
                        nlohmann::json* outValue);

}  // namespace cc
