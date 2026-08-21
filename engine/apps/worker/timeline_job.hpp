// Timeline render job implementation — see timeline_main.cpp for the job
// contract. Video: per-frame cc::renderFrame → RGBA → yuv420p → encoder.
// Audio: per-clip PCM decode scheduled on the sequence timeline with fades,
// gain, pan and constant-power crossfades inside transition overlaps.

#pragma once

#include <chrono>
#include <map>
#include <string>

#include <nlohmann/json.hpp>

namespace cc {

inline double lastJobSecondsValue = 0.0;
inline long long lastJobBytesValue = 0;

inline double lastJobSeconds() { return lastJobSecondsValue; }
inline long long lastJobBytes() { return lastJobBytesValue; }

nlohmann::json parseJobFile(const std::string& path);

// Runs the job; emits progress lines; returns process exit code.
int runTimelineJob(const nlohmann::json& spec);

}  // namespace cc
