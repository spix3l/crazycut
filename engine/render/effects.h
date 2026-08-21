#pragma once

#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "core/result.h"

#include "core/time.h"
namespace cc {

// One animatable-or-static parameter slot declared by an effect (KEY-1).
struct EffectParamDef {
  std::string id;
  std::string label;
  std::string type;  // float | point | color | enum
  double min = 0.0;
  double max = 1.0;
  double def = 0.0;
  std::string unit;      // e.g. "px@1080"; empty when dimensionless
  bool statik = false;   // true = not keyframeable (FX-4)
  std::vector<std::string> options;  // enum choices
};

struct EffectDef {
  std::string id;
  std::string label;
  std::string category;
  std::vector<EffectParamDef> params;

  const EffectParamDef* param(const std::string& id) const;
};

// The v1 catalog from docs/03-features/effects.md. Defined once here; the UI
// reads it through cc_effect_catalog() so params never drift between sides.
const std::vector<EffectDef>& effectCatalog();
const EffectDef* findEffect(const std::string& id);
std::string effectCatalogJson();

// An effect instance resolved for rendering: definition + evaluated params.
struct ResolvedEffect {
  const EffectDef* def = nullptr;
  nlohmann::json params;  // param id -> evaluated value
};

// Evaluates an instance {"type","enabled","params"} at clip-local time.
// Returns nullopt when the instance is disabled or unknown (skip silently).
std::optional<ResolvedEffect> resolveEffect(const nlohmann::json& instance,
                                            const RationalTime& localTime);

struct RgbaSurface {
  int width = 0;
  int height = 0;
  std::vector<uint8_t> rgba;  // straight alpha, row-major
};

struct RenderContext {
  int sequenceWidth = 1920;
  int sequenceHeight = 1080;

  // Height used to normalise "px@1080" units (FX-7).
  double unitScale() const {
    return sequenceHeight <= 0 ? 1.0 : static_cast<double>(sequenceHeight) / 1080.0;
  }
};

// Applies one resolved effect to the surface in place. Order semantics are the
// caller's concern (list top-down, top applied first — FX-1).
Error applyEffect(const ResolvedEffect& effect, const RenderContext& ctx,
                  RgbaSurface* image);

}  // namespace cc
