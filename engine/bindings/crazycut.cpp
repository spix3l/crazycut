#include "bindings/crazycut.h"

#include <cstdlib>
#include <string>
#include <vector>

#include "core/result.h"
#include "media/frame.h"
#include "media/probe.h"
#include "playback/player.h"

struct cc_engine {
  std::string jsonBuffer;
};

extern "C" {

int32_t cc_abi_version(void) { return CC_ABI_VERSION; }

cc_engine* cc_engine_create(void) { return new (std::nothrow) cc_engine(); }

void cc_engine_destroy(cc_engine* engine) { delete engine; }

const char* cc_last_error(void) { return cc::lastError(); }

int32_t cc_probe_file(cc_engine* engine, const char* utf8_path, const char** out_json) {
  if (!engine || !utf8_path || !out_json) {
    cc::setLastError("cc_probe_file: null argument");
    return static_cast<int32_t>(cc::Error::InvalidArgument);
  }
  std::string json;
  const cc::Error err = cc::probeFile(utf8_path, &json);
  if (err != cc::Error::None) {
    return static_cast<int32_t>(err);
  }
  engine->jsonBuffer = std::move(json);
  *out_json = engine->jsonBuffer.c_str();
  return 0;
}

int32_t cc_extract_thumbnail(cc_engine* engine, const char* utf8_path, double seconds,
                             int32_t width, uint8_t** out_jpeg, int32_t* out_len) {
  (void)engine;
  if (!utf8_path || !out_jpeg || !out_len) {
    cc::setLastError("cc_extract_thumbnail: null argument");
    return static_cast<int32_t>(cc::Error::InvalidArgument);
  }
  std::vector<uint8_t> jpeg;
  const cc::Error err = cc::extractThumbnailJpeg(utf8_path, seconds, width, &jpeg);
  if (err != cc::Error::None) {
    return static_cast<int32_t>(err);
  }
  uint8_t* copy = static_cast<uint8_t*>(malloc(jpeg.size()));
  if (!copy) {
    cc::setLastError("out of memory");
    return static_cast<int32_t>(cc::Error::InternalError);
  }
  memcpy(copy, jpeg.data(), jpeg.size());
  *out_jpeg = copy;
  *out_len = static_cast<int32_t>(jpeg.size());
  return 0;
}

int32_t cc_extract_frame_rgba(cc_engine* engine, const char* utf8_path, double seconds,
                              int32_t width, int32_t* out_w, int32_t* out_h,
                              uint8_t** out_rgba) {
  (void)engine;
  if (!utf8_path || !out_w || !out_h || !out_rgba) {
    cc::setLastError("cc_extract_frame_rgba: null argument");
    return static_cast<int32_t>(cc::Error::InvalidArgument);
  }
  cc::DecodedFrame frame;
  const cc::Error err = cc::extractFrameRgba(utf8_path, seconds, width, &frame);
  if (err != cc::Error::None) {
    return static_cast<int32_t>(err);
  }
  uint8_t* copy = static_cast<uint8_t*>(malloc(frame.rgba.size()));
  if (!copy) {
    cc::setLastError("out of memory");
    return static_cast<int32_t>(cc::Error::InternalError);
  }
  memcpy(copy, frame.rgba.data(), frame.rgba.size());
  *out_w = frame.width;
  *out_h = frame.height;
  *out_rgba = copy;
  return 0;
}

void cc_buffer_free(uint8_t* buffer) { free(buffer); }

cc_playback* cc_playback_create(const char* utf8_path) {
  if (!utf8_path) {
    cc::setLastError("cc_playback_create: null path");
    return nullptr;
  }
  return reinterpret_cast<cc_playback*>(cc::PlaybackSession::create(utf8_path, 960));
}

void cc_playback_destroy(cc_playback* playback) {
  delete reinterpret_cast<cc::PlaybackSession*>(playback);
}

int32_t cc_playback_start(cc_playback* playback) {
  if (!playback) return static_cast<int32_t>(cc::Error::InvalidArgument);
  return static_cast<int32_t>(
      reinterpret_cast<cc::PlaybackSession*>(playback)->start());
}

void cc_playback_pause(cc_playback* playback) {
  if (playback)
    reinterpret_cast<cc::PlaybackSession*>(playback)->pause();
}

void cc_playback_resume(cc_playback* playback) {
  if (playback)
    reinterpret_cast<cc::PlaybackSession*>(playback)->resume();
}

int32_t cc_playback_is_playing(cc_playback* playback) {
  return playback && reinterpret_cast<cc::PlaybackSession*>(playback)->isPlaying()
             ? 1
             : 0;
}

int32_t cc_playback_seek(cc_playback* playback, double seconds) {
  if (!playback) return static_cast<int32_t>(cc::Error::InvalidArgument);
  return static_cast<int32_t>(
      reinterpret_cast<cc::PlaybackSession*>(playback)->seek(seconds));
}

double cc_playback_position(cc_playback* playback) {
  return playback ? reinterpret_cast<cc::PlaybackSession*>(playback)->positionSeconds()
                  : 0.0;
}

double cc_playback_duration(cc_playback* playback) {
  return playback
             ? reinterpret_cast<cc::PlaybackSession*>(playback)->durationSeconds()
             : 0.0;
}

double cc_playback_fps(cc_playback* playback) {
  return playback ? reinterpret_cast<cc::PlaybackSession*>(playback)->fps() : 30.0;
}

int32_t cc_playback_reached_end(cc_playback* playback) {
  return playback &&
                 reinterpret_cast<cc::PlaybackSession*>(playback)->reachedEnd()
             ? 1
             : 0;
}

const uint8_t* cc_playback_lock_frame(cc_playback* playback, int32_t* out_w,
                                      int32_t* out_h) {
  if (!playback || !out_w || !out_h) return nullptr;
  return reinterpret_cast<cc::PlaybackSession*>(playback)->lockFrame(
      out_w, out_h);
}

void cc_playback_unlock_frame(cc_playback* playback) {
  if (playback)
    reinterpret_cast<cc::PlaybackSession*>(playback)->unlockFrame();
}

}  // extern "C"
