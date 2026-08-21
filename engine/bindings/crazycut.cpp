#include "bindings/crazycut.h"

#include <cstdlib>
#include <string>
#include <vector>

#include "core/result.h"
#include "graph/keyframes.h"
#include "media/frame.h"
#include "media/prepare.h"
#include "media/probe.h"
#include "model/project.h"
#include "playback/player.h"
#include "render/effects.h"
#include "render/renderer.h"


namespace {
thread_local std::string g_value_buffer;
}

extern "C" {

struct cc_engine {
  std::string jsonBuffer;
  cc::ProjectSnapshot project;
};

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

int32_t cc_project_set_snapshot(cc_engine* engine, const char* utf8_json,
                                int32_t repair_invalid,
                                const char** out_report_json) {
  if (!engine || !utf8_json || !out_report_json) {
    cc::setLastError("cc_project_set_snapshot: null argument");
    return static_cast<int32_t>(cc::Error::InvalidArgument);
  }
  const cc::Error error = engine->project.load(utf8_json, repair_invalid != 0);
  if (error != cc::Error::None) return static_cast<int32_t>(error);
  engine->jsonBuffer = engine->project.reportJson();
  *out_report_json = engine->jsonBuffer.c_str();
  return 0;
}

int32_t cc_project_get_snapshot(cc_engine* engine, const char** out_json) {
  if (!engine || !out_json) {
    cc::setLastError("cc_project_get_snapshot: null argument");
    return static_cast<int32_t>(cc::Error::InvalidArgument);
  }
  engine->jsonBuffer = engine->project.jsonString();
  *out_json = engine->jsonBuffer.c_str();
  return 0;
}

double cc_project_duration(cc_engine* engine) {
  return engine ? engine->project.duration().toSeconds() : 0.0;
}

int32_t cc_evaluate_parameter(const char* utf8_parameter_json,
                              int64_t time_num, int32_t time_den,
                              const char** out_value_json) {
  if (!utf8_parameter_json || !out_value_json || time_den <= 0) {
    cc::setLastError("cc_evaluate_parameter: invalid argument");
    return static_cast<int32_t>(cc::Error::InvalidArgument);
  }
  try {
    nlohmann::json parameter = nlohmann::json::parse(utf8_parameter_json);
    nlohmann::json value;
    const cc::Error error = cc::evaluateParameter(
        parameter, cc::RationalTime{time_num, time_den}.normalized(), &value);
    if (error != cc::Error::None) {
      cc::setLastError("invalid keyframe parameter");
      return static_cast<int32_t>(error);
    }
    g_value_buffer = value.dump();
    *out_value_json = g_value_buffer.c_str();
    return 0;
  } catch (const std::exception& e) {
    cc::setLastError(std::string("parameter JSON error: ") + e.what());
    return static_cast<int32_t>(cc::Error::InvalidArgument);
  }
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

int32_t cc_hash_file(cc_engine* engine, const char* utf8_path,
                     const char** out_hash) {
  if (!engine || !utf8_path || !out_hash) {
    cc::setLastError("cc_hash_file: null argument");
    return static_cast<int32_t>(cc::Error::InvalidArgument);
  }
  const cc::Error error = cc::hashFileSha256(utf8_path, &engine->jsonBuffer);
  if (error != cc::Error::None) return static_cast<int32_t>(error);
  *out_hash = engine->jsonBuffer.c_str();
  return 0;
}

int32_t cc_extract_waveform(cc_engine* engine, const char* utf8_path,
                            int32_t peaks_per_second, const char** out_json) {
  if (!engine || !utf8_path || !out_json) {
    cc::setLastError("cc_extract_waveform: null argument");
    return static_cast<int32_t>(cc::Error::InvalidArgument);
  }
  const cc::Error error = cc::extractWaveform(utf8_path, peaks_per_second,
                                               &engine->jsonBuffer);
  if (error != cc::Error::None) return static_cast<int32_t>(error);
  *out_json = engine->jsonBuffer.c_str();
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

int32_t cc_render_frame_rgba(cc_engine* engine, int64_t time_num,
                             int32_t time_den, int32_t width, int32_t height,
                             int32_t media_count, const char** utf8_keys,
                             const char** utf8_paths, int32_t texture_count,
                             const char** texture_keys,
                             const cc_rgba_texture* textures, uint8_t** out_rgba) {
  if (!engine || !out_rgba || width <= 0 || height <= 0 || time_den <= 0 ||
      media_count < 0 || texture_count < 0) {
    cc::setLastError("cc_render_frame_rgba: invalid argument");
    return static_cast<int32_t>(cc::Error::InvalidArgument);
  }
  try {
    std::map<std::string, std::string> paths;
    for (int32_t i = 0; i < media_count; ++i) {
      if (utf8_keys[i] && utf8_paths[i]) paths[utf8_keys[i]] = utf8_paths[i];
    }
    // Text textures arrive per call; copy them into surfaces once.
    std::map<std::string, cc::RgbaSurface> tex;
    for (int32_t i = 0; i < texture_count; ++i) {
      if (!texture_keys[i] || !textures[i].bytes || textures[i].width <= 0 ||
          textures[i].height <= 0) {
        continue;
      }
      cc::RgbaSurface surf;
      surf.width = textures[i].width;
      surf.height = textures[i].height;
      surf.rgba.assign(textures[i].bytes,
                       textures[i].bytes +
                           static_cast<size_t>(textures[i].width) *
                               textures[i].height * 4);
      tex[texture_keys[i]] = std::move(surf);
    }
    cc::RgbaSurface out;
    const cc::Error err = cc::renderFrame(
        engine->project.document(),
        cc::RationalTime{time_num, time_den}.normalized(), width, height,
        [&](const std::string& key) -> std::optional<cc::ClipSource> {
          if (const auto it = tex.find(key); it != tex.end()) {
            cc::ClipSource src;
            src.texture = it->second;
            return src;
          }
          if (const auto it = paths.find(key); it != paths.end()) {
            cc::ClipSource src;
            src.path = it->second;
            return src;
          }
          return std::nullopt;
        },
        &out);
    if (err != cc::Error::None) return static_cast<int32_t>(err);
    uint8_t* copy = static_cast<uint8_t*>(malloc(out.rgba.size()));
    if (!copy) {
      cc::setLastError("out of memory");
      return static_cast<int32_t>(cc::Error::InternalError);
    }
    memcpy(copy, out.rgba.data(), out.rgba.size());
    *out_rgba = copy;
    return 0;
  } catch (const std::exception& e) {
    cc::setLastError(std::string("render frame error: ") + e.what());
    return static_cast<int32_t>(cc::Error::InternalError);
  }
}

int32_t cc_effect_catalog(cc_engine* engine, const char** out_json) {
  if (!engine || !out_json) {
    cc::setLastError("cc_effect_catalog: null argument");
    return static_cast<int32_t>(cc::Error::InvalidArgument);
  }
  engine->jsonBuffer = cc::effectCatalogJson();
  *out_json = engine->jsonBuffer.c_str();
  return 0;
}

}
