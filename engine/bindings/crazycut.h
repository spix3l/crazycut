#ifndef CRAZYCUT_BINDINGS_CRAZYCUT_H
#define CRAZYCUT_BINDINGS_CRAZYCUT_H

#include <stdint.h>

#ifdef _WIN32
#define CC_EXPORT __declspec(dllexport)
#else
#define CC_EXPORT __attribute__((visibility("default")))
#endif

#define CC_ABI_VERSION 1

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cc_engine cc_engine;

CC_EXPORT int32_t cc_abi_version(void);

CC_EXPORT cc_engine* cc_engine_create(void);
CC_EXPORT void cc_engine_destroy(cc_engine* engine);

CC_EXPORT const char* cc_last_error(void);

CC_EXPORT int32_t cc_probe_file(cc_engine* engine, const char* utf8_path,
                                const char** out_json);

// Installs a disposable render-graph snapshot. The document remains owned by
// Dart; the engine validates and canonicalizes its private copy. Returned
// strings remain valid until the next project call on this engine handle.
CC_EXPORT int32_t cc_project_set_snapshot(cc_engine* engine, const char* utf8_json,
                                          int32_t repair_invalid,
                                          const char** out_report_json);
CC_EXPORT int32_t cc_project_get_snapshot(cc_engine* engine, const char** out_json);
CC_EXPORT double cc_project_duration(cc_engine* engine);

// Pure keyframe evaluator used by both preview and export paths.
CC_EXPORT int32_t cc_evaluate_parameter(const char* utf8_parameter_json,
                                        int64_t time_num, int32_t time_den,
                                        const char** out_value_json);

CC_EXPORT int32_t cc_extract_thumbnail(cc_engine* engine, const char* utf8_path,
                                       double seconds, int32_t width, uint8_t** out_jpeg,
                                       int32_t* out_len);

CC_EXPORT int32_t cc_extract_frame_rgba(cc_engine* engine, const char* utf8_path,
                                        double seconds, int32_t width, int32_t* out_w,
                                        int32_t* out_h, uint8_t** out_rgba);

CC_EXPORT int32_t cc_hash_file(cc_engine* engine, const char* utf8_path,
                               const char** out_hash);
CC_EXPORT int32_t cc_extract_waveform(cc_engine* engine, const char* utf8_path,
                                      int32_t peaks_per_second,
                                      const char** out_json);

CC_EXPORT void cc_buffer_free(uint8_t* buffer);

typedef struct cc_playback cc_playback;

CC_EXPORT cc_playback* cc_playback_create(const char* utf8_path);
CC_EXPORT void cc_playback_destroy(cc_playback* playback);
CC_EXPORT int32_t cc_playback_start(cc_playback* playback);
CC_EXPORT void cc_playback_pause(cc_playback* playback);
CC_EXPORT void cc_playback_resume(cc_playback* playback);
CC_EXPORT int32_t cc_playback_is_playing(cc_playback* playback);
CC_EXPORT int32_t cc_playback_seek(cc_playback* playback, double seconds);
CC_EXPORT double cc_playback_position(cc_playback* playback);
CC_EXPORT double cc_playback_duration(cc_playback* playback);
CC_EXPORT double cc_playback_fps(cc_playback* playback);
CC_EXPORT int32_t cc_playback_reached_end(cc_playback* playback);

CC_EXPORT const uint8_t* cc_playback_lock_frame(cc_playback* playback,
                                                int32_t* out_w, int32_t* out_h);
CC_EXPORT void cc_playback_unlock_frame(cc_playback* playback);

#ifdef __cplusplus
}
#endif

#endif
