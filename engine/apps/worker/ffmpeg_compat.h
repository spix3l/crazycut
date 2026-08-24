#pragma once

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/version_major.h>
}

namespace cc {

inline AVSampleFormat firstSupportedSampleFormat(
    const AVCodec* codec, AVSampleFormat fallback) {
#if LIBAVCODEC_VERSION_MAJOR >= 62
  const void* configs = nullptr;
  int count = 0;
  if (avcodec_get_supported_config(nullptr, codec,
                                   AV_CODEC_CONFIG_SAMPLE_FORMAT, 0,
                                   &configs, &count) >= 0 &&
      configs != nullptr && count > 0) {
    return static_cast<const AVSampleFormat*>(configs)[0];
  }
  return fallback;
#else
  return codec->sample_fmts ? codec->sample_fmts[0] : fallback;
#endif
}

}  // namespace cc
