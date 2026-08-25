#pragma once

#include <functional>
#include <string>

#include "core/result.h"

namespace cc {

/// Reports progress in [0,1] and returns false to ask for cancellation.
using TranscribeProgress = std::function<bool(double)>;

/// True when the engine was built with speech-to-text support. The worker
/// reports a clear message rather than a crash when it was not (AI-19).
bool transcriptionAvailable();

/// Transcribes the audio of [mediaPath] using the whisper-class model at
/// [modelPath], writing timed segments as JSON to [outJson] (AI-18, AI-22).
///
/// Times are seconds in the media's own domain, so segment boundaries are
/// directly usable as cut points. [language] may be "auto".
Error transcribe(const std::string& mediaPath, const std::string& modelPath,
                 const std::string& language, int threads,
                 std::string* outJson, const TranscribeProgress& onProgress);

}  // namespace cc
