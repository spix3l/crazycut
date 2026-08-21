#include "model/project.h"

#include <algorithm>
#include <filesystem>
#include <set>
#include <unordered_map>
#include <unordered_set>

namespace cc {
namespace {

using json = nlohmann::json;

void addIssue(std::vector<ValidationIssue>* issues, std::string code,
              std::string type, std::string id, std::string message,
              bool repaired) {
  issues->push_back({std::move(code), std::move(type), std::move(id),
                     std::move(message), repaired});
}

std::string idOf(const json& entity) {
  return entity.is_object() ? entity.value("id", "") : "";
}

bool validKind(const std::string& kind, const char* a, const char* b) {
  return kind == a || kind == b;
}

bool canonicalizeTime(json* owner, const char* key, bool allowZero,
                      std::vector<ValidationIssue>* issues,
                      const std::string& type, const std::string& id) {
  if (!owner->contains(key)) return false;
  const auto parsed = parseJsonTime((*owner)[key]);
  if (!parsed || (!allowZero && parsed->num <= 0) || parsed->num < 0) {
    addIssue(issues, "invalid_time", type, id,
             std::string(key) + " must be a normalized non-negative rational",
             false);
    return false;
  }
  (*owner)[key] = parsed->toString();
  return true;
}

bool keyframesValid(json* clip, std::vector<ValidationIssue>* issues,
                    const RationalTime& duration) {
  if (!clip->contains("effects") || !(*clip)["effects"].is_array()) return true;
  bool valid = true;
  for (auto& effect : (*clip)["effects"]) {
    if (!effect.is_object() || !effect.contains("params") ||
        !effect["params"].is_object()) continue;
    for (auto& [name, param] : effect["params"].items()) {
      if (!param.is_object() || !param.contains("keyframes")) continue;
      if (!param["keyframes"].is_array()) {
        addIssue(issues, "invalid_keyframes", "clip", idOf(*clip),
                 "effect parameter " + name + " keyframes must be an array", false);
        valid = false;
        continue;
      }
      RationalTime previous{-1, 1};
      for (auto& key : param["keyframes"]) {
        if (!key.is_object() || !key.contains("t")) {
          valid = false;
          continue;
        }
        const auto t = parseJsonTime(key["t"]);
        if (!t || *t < RationalTime{} || *t > duration || *t <= previous) {
          addIssue(issues, "invalid_keyframe_time", "clip", idOf(*clip),
                   "keyframes must be strictly increasing and inside the clip", false);
          valid = false;
          break;
        }
        key["t"] = t->toString();
        previous = *t;
      }
    }
  }
  return valid;
}

}  // namespace

std::optional<RationalTime> parseJsonTime(const nlohmann::json& value) {
  if (value.is_string()) return parseRationalTime(value.get<std::string>());
  if (!value.is_object() || !value.contains("n") || !value.contains("d") ||
      !value["n"].is_number_integer() || !value["d"].is_number_integer()) {
    return std::nullopt;
  }
  const int64_t n = value["n"].get<int64_t>();
  const int64_t d = value["d"].get<int64_t>();
  if (d <= 0 || d > INT32_MAX) return std::nullopt;
  return RationalTime{n, static_cast<int32_t>(d)}.normalized();
}

Error ProjectSnapshot::load(const std::string& jsonText, bool repairInvalid) {
  issues_.clear();
  duration_ = {};
  try {
    document_ = json::parse(jsonText);
  } catch (const std::exception& e) {
    setLastError(std::string("invalid project JSON: ") + e.what());
    return Error::InvalidArgument;
  }
  if (!document_.is_object()) {
    setLastError("project root must be an object");
    return Error::InvalidArgument;
  }
  const std::string schema = document_.value("schema", "");
  if (schema != "crazycut/project@1") {
    setLastError(schema.empty() ? "project schema is missing"
                                : "unsupported project schema: " + schema);
    return Error::InvalidArgument;
  }
  for (const char* field : {"media", "tracks", "clips", "transitions", "markers"}) {
    if (!document_.contains(field)) document_[field] = json::array();
    if (!document_[field].is_array()) {
      setLastError(std::string("project field must be an array: ") + field);
      return Error::InvalidArgument;
    }
  }
  if (!document_.contains("settings") || !document_["settings"].is_object()) {
    setLastError("project settings are missing");
    return Error::InvalidArgument;
  }
  auto& settings = document_["settings"];
  if (settings.value("width", 0) <= 0 || settings.value("height", 0) <= 0 ||
      settings.value("audioSampleRate", 0) <= 0 ||
      !settings.contains("fps") || !parseJsonTime(settings["fps"]) ||
      parseJsonTime(settings["fps"])->num <= 0) {
    setLastError("invalid sequence settings");
    return Error::InvalidArgument;
  }
  settings["fps"] = parseJsonTime(settings["fps"])->toString();

  std::unordered_set<std::string> mediaIds;
  std::unordered_map<std::string, RationalTime> mediaDurations;
  for (const auto& media : document_["media"]) {
    const std::string id = idOf(media);
    if (id.empty() || !mediaIds.insert(id).second) {
      addIssue(&issues_, "invalid_media_id", "media", id,
               "media ids must be non-empty and unique", false);
      continue;
    }
    if (media.contains("duration")) {
      if (auto t = parseJsonTime(media["duration"])) mediaDurations[id] = *t;
    }
  }

  std::unordered_map<std::string, std::string> trackKinds;
  std::set<std::pair<std::string, int>> trackIndices;
  for (const auto& track : document_["tracks"]) {
    const std::string id = idOf(track);
    const std::string kind = track.value("kind", "");
    const int index = track.value("index", -1);
    if (id.empty() || trackKinds.count(id) || !validKind(kind, "video", "audio") ||
        index < 0 || !trackIndices.insert({kind, index}).second) {
      addIssue(&issues_, "invalid_track", "track", id,
               "track id/kind/index must be valid and unique", false);
      continue;
    }
    trackKinds[id] = kind;
  }

  json validClips = json::array();
  std::unordered_map<std::string, json> clipsById;
  struct ClipRange { RationalTime start; RationalTime end; std::string id; };
  std::unordered_map<std::string, std::vector<ClipRange>> ranges;
  for (auto clip : document_["clips"]) {
    const std::string id = idOf(clip);
    bool valid = clip.is_object() && !id.empty() && !clipsById.count(id);
    const std::string trackId = clip.value("trackId", "");
    const std::string mediaId = clip.value("mediaId", "");
    valid = valid && trackKinds.count(trackId);
    if (!mediaId.empty()) valid = valid && mediaIds.count(mediaId);
    valid = valid && canonicalizeTime(&clip, "start", true, &issues_, "clip", id);
    valid = valid && canonicalizeTime(&clip, "duration", false, &issues_, "clip", id);
    if (clip.contains("sourceIn"))
      valid = valid && canonicalizeTime(&clip, "sourceIn", true, &issues_, "clip", id);
    auto start = clip.contains("start") ? parseJsonTime(clip["start"]) : std::nullopt;
    auto duration = clip.contains("duration") ? parseJsonTime(clip["duration"]) : std::nullopt;
    valid = valid && start && duration && keyframesValid(&clip, &issues_, *duration);
    if (valid && !mediaId.empty() && mediaDurations.count(mediaId) &&
        clip.contains("sourceIn")) {
      const auto sourceIn = parseJsonTime(clip["sourceIn"]);
      RationalTime speed{1, 1};
      if (clip.contains("speed")) {
        const auto& s = clip["speed"];
        if (s.is_string()) speed = parseRationalTime(s.get<std::string>()).value_or(speed);
        else if (s.is_object()) speed = RationalTime{s.value("num", 1), s.value("den", 1)}.normalized();
      }
      if (!sourceIn || speed < RationalTime{1, 4} || speed > RationalTime{4, 1} ||
          *sourceIn + RationalTime{duration->num * speed.num,
                                   static_cast<int32_t>(duration->den * speed.den)}.normalized() >
              mediaDurations[mediaId]) {
        addIssue(&issues_, "source_range_exceeded", "clip", id,
                 "clip source range exceeds its media", false);
        valid = false;
      }
    }
    if (!valid) {
      addIssue(&issues_, "invalid_clip", "clip", id,
               "clip was excluded from the render graph", repairInvalid);
      if (!repairInvalid) validClips.push_back(std::move(clip));
      continue;
    }
    const RationalTime end = *start + *duration;
    duration_ = std::max(duration_, end);
    ranges[trackId].push_back({*start, end, id});
    clipsById[id] = clip;
    validClips.push_back(std::move(clip));
  }
  if (repairInvalid) document_["clips"] = std::move(validClips);

  // Audio overlaps are never legal. Video overlaps require a matching transition.
  std::unordered_set<std::string> transitionPairs;
  json validTransitions = json::array();
  for (auto tr : document_["transitions"]) {
    const std::string id = idOf(tr);
    const std::string a = tr.value("aClipId", "");
    const std::string b = tr.value("bClipId", "");
    bool valid = clipsById.count(a) && clipsById.count(b) &&
                 clipsById[a].value("trackId", "") == clipsById[b].value("trackId", "") &&
                 canonicalizeTime(&tr, "duration", false, &issues_, "transition", id);
    if (valid) {
      const auto aStart = parseJsonTime(clipsById[a]["start"]);
      const auto aDuration = parseJsonTime(clipsById[a]["duration"]);
      const auto bStart = parseJsonTime(clipsById[b]["start"]);
      const auto bDuration = parseJsonTime(clipsById[b]["duration"]);
      const auto transitionDuration = parseJsonTime(tr["duration"]);
      const RationalTime overlapStart = std::max(*aStart, *bStart);
      const RationalTime overlapEnd = std::min(*aStart + *aDuration,
                                                *bStart + *bDuration);
      valid = overlapEnd > overlapStart &&
              overlapEnd - overlapStart == *transitionDuration;
    }
    if (valid) {
      transitionPairs.insert(a + "\n" + b);
      transitionPairs.insert(b + "\n" + a);
    }
    if (valid || !repairInvalid) validTransitions.push_back(std::move(tr));
    else addIssue(&issues_, "invalid_transition", "transition", id,
                  "transition references invalid or cross-track clips", true);
  }
  if (repairInvalid) document_["transitions"] = std::move(validTransitions);

  for (auto& [trackId, trackRanges] : ranges) {
    std::sort(trackRanges.begin(), trackRanges.end(),
              [](const ClipRange& a, const ClipRange& b) { return a.start < b.start; });
    for (size_t i = 1; i < trackRanges.size(); ++i) {
      if (trackRanges[i].start < trackRanges[i - 1].end &&
          (trackKinds[trackId] == "audio" ||
           !transitionPairs.count(trackRanges[i - 1].id + "\n" + trackRanges[i].id))) {
        addIssue(&issues_, trackKinds[trackId] == "audio" ? "audio_overlap" : "video_overlap",
                 "track", trackId,
                 "overlapping clips require distinct audio tracks or a valid transition", false);
      }
    }
  }
  return Error::None;
}

size_t ProjectSnapshot::mediaCount() const { return document_.value("media", json::array()).size(); }
size_t ProjectSnapshot::trackCount() const { return document_.value("tracks", json::array()).size(); }
size_t ProjectSnapshot::clipCount() const { return document_.value("clips", json::array()).size(); }
std::string ProjectSnapshot::jsonString() const { return document_.dump(); }

std::string ProjectSnapshot::reportJson() const {
  const bool valid = std::none_of(issues_.begin(), issues_.end(),
                                  [](const ValidationIssue& issue) {
                                    return !issue.repaired;
                                  });
  json report = {{"valid", valid},
                 {"duration", duration_.toString()},
                 {"mediaCount", mediaCount()},
                 {"trackCount", trackCount()},
                 {"clipCount", clipCount()},
                 {"issues", json::array()}};
  for (const auto& issue : issues_) {
    report["issues"].push_back({{"code", issue.code},
                                {"entityType", issue.entityType},
                                {"entityId", issue.entityId},
                                {"message", issue.message},
                                {"repaired", issue.repaired}});
  }
  return report.dump();
}

}  // namespace cc
