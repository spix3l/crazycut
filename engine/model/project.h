#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "core/result.h"
#include "core/time.h"

namespace cc {

struct ValidationIssue {
  std::string code;
  std::string entityType;
  std::string entityId;
  std::string message;
  bool repaired = false;
};

class ProjectSnapshot {
 public:
  Error load(const std::string& jsonText, bool repairInvalid = true);

  const nlohmann::json& document() const { return document_; }
  const std::vector<ValidationIssue>& issues() const { return issues_; }
  RationalTime duration() const { return duration_; }
  size_t mediaCount() const;
  size_t trackCount() const;
  size_t clipCount() const;

  std::string jsonString() const;
  std::string reportJson() const;

 private:
  nlohmann::json document_;
  std::vector<ValidationIssue> issues_;
  RationalTime duration_{};
};

// Accepts both canonical "n/d" strings and the verbose {n,d} form.
std::optional<RationalTime> parseJsonTime(const nlohmann::json& value);

}  // namespace cc
