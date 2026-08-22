#pragma once

#include <string>
#include <vector>

#include "core/result.h"

namespace cc {

// Decodes a range of an asset's audio to interleaved stereo float at
// [sampleRate], resampling and downmixing whatever the source is (5.1 sources
// fold to stereo, AUD edge cases).
//
// [sourceInSec] is the offset inside the file; [seconds] the amount wanted.
// The output always contains exactly ceil(seconds * sampleRate) frames —
// short or absent audio is padded with silence, so callers can mix without
// bounds juggling. Files with no audio stream yield silence and Error::None.
//
// Decoders are cached per thread (like the video path), so mixing successive
// chunks of the same asset during playback does not reopen the file.
Error decodeStereoRange(const std::string& path, double sourceInSec,
                        double seconds, int sampleRate,
                        std::vector<float>* outInterleaved);

// True when the file has a decodable audio stream (cached alongside the
// decoder, so this is cheap after the first call).
bool hasAudioStream(const std::string& path);

// Peak absolute sample of the whole file, for normalize (AUD-5).
Error scanPeak(const std::string& path, double sourceInSec, double seconds,
               int sampleRate, float* outPeak);

}  // namespace cc
