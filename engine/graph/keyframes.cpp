#include "graph/keyframes.h"

#include <algorithm>
#include <cmath>

#include "model/project.h"

namespace cc {
namespace {

double eased(double x, const std::string& interpolation) {
  x = std::clamp(x, 0.0, 1.0);
  if (interpolation == "hold") return 0.0;
  if (interpolation == "easeIn") return x * x;
  if (interpolation == "easeOut") return 1.0 - (1.0 - x) * (1.0 - x);
  if (interpolation == "easeInOut") return x * x * (3.0 - 2.0 * x);
  return x;
}

nlohmann::json interpolate(const nlohmann::json& a, const nlohmann::json& b, double x) {
  if (a.is_number() && b.is_number()) {
    return a.get<double>() + (b.get<double>() - a.get<double>()) * x;
  }
  if (a.is_object() && b.is_object()) {
    nlohmann::json result = a;
    for (auto& [key, value] : result.items()) {
      if (b.contains(key)) value = interpolate(value, b[key], x);
    }
    return result;
  }
  return x < 1.0 ? a : b;
}

}  // namespace

Error evaluateParameter(const nlohmann::json& parameter, const RationalTime& time,
                        nlohmann::json* outValue) {
  if (!outValue || !parameter.is_object()) return Error::InvalidArgument;
  if (!parameter.contains("keyframes") || !parameter["keyframes"].is_array() ||
      parameter["keyframes"].empty()) {
    if (!parameter.contains("static")) return Error::InvalidArgument;
    *outValue = parameter["static"];
    return Error::None;
  }
  const auto& keys = parameter["keyframes"];
  const auto firstTime = parseJsonTime(keys.front().at("t"));
  const auto lastTime = parseJsonTime(keys.back().at("t"));
  if (!firstTime || !lastTime) return Error::InvalidArgument;
  if (time <= *firstTime) { *outValue = keys.front().at("v"); return Error::None; }
  if (time >= *lastTime) { *outValue = keys.back().at("v"); return Error::None; }
  for (size_t i = 1; i < keys.size(); ++i) {
    const auto rightTime = parseJsonTime(keys[i].at("t"));
    const auto leftTime = parseJsonTime(keys[i - 1].at("t"));
    if (!leftTime || !rightTime || *rightTime <= *leftTime) return Error::InvalidArgument;
    if (time <= *rightTime) {
      const double span = (*rightTime - *leftTime).toSeconds();
      const double p = eased((time - *leftTime).toSeconds() / span,
                             keys[i - 1].value("interp", "linear"));
      *outValue = interpolate(keys[i - 1].at("v"), keys[i].at("v"), p);
      return Error::None;
    }
  }
  return Error::InternalError;
}

}  // namespace cc
