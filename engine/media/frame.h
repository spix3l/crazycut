#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "core/result.h"

namespace cc {

struct DecodedFrame {
  int width = 0;
  int height = 0;
  std::vector<uint8_t> rgba;
};

Error extractFrameRgba(const std::string& path, double seconds, int targetWidth,
                       DecodedFrame* outFrame);

Error extractThumbnailJpeg(const std::string& path, double seconds, int width,
                           std::vector<uint8_t>* outJpeg);

}  // namespace cc
