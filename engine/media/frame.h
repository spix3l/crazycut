#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "core/result.h"

struct AVFrame;  // libavutil; declared here to keep ffmpeg headers out of this one

namespace cc {

struct DecodedFrame {
  int width = 0;
  int height = 0;
  std::vector<uint8_t> rgba;
};

Error extractFrameRgba(const std::string& path, double seconds, int targetWidth,
                       DecodedFrame* outFrame);

// The frame covering [seconds] in the codec's own pixel format, borrowed from
// this thread's decoder session: valid only until the next decode call on this
// thread, and never to be freed by the caller. [outRotation], when given,
// receives the display rotation extractFrameRgba would have baked in.
//
// This exists for the export's passthrough path, which hands a decoded frame
// straight to the encoder. It shares the session cache with extractFrameRgba,
// so falling back to the RGBA path after calling this costs nothing: the same
// frame is still decoded and held.
Error extractFrameNative(const std::string& path, double seconds,
                         AVFrame** outFrame, int* outRotation);

Error extractThumbnailJpeg(const std::string& path, double seconds, int width,
                           std::vector<uint8_t>* outJpeg);

}  // namespace cc
