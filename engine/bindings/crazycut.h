#ifndef CRAZYCUT_BINDINGS_CRAZYCUT_H
#define CRAZYCUT_BINDINGS_CRAZYCUT_H

#include <stdint.h>

#ifdef _WIN32
#define CC_EXPORT __declspec(dllexport)
#else
#define CC_EXPORT __attribute__((visibility("default")))
#endif

// 4: the project snapshot gained `trackers[]` and the transform's `corners`
// param (docs/03-features/tracking.md, TRK-13/TRK-20).
#define CC_ABI_VERSION 4

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

// Renders one composited frame of the installed snapshot at sequence time
// (num/den seconds) into out_rgba (RGBA8, width×height, caller frees via
// cc_buffer_free). Media paths map asset id → file path; text clips are keyed
// "text:<clipId>" with a pre-rasterized RGBA texture (width/height/bytes).
// Missing entries render the offline slate. This is the exact function the
// export worker uses per frame — preview == export by construction.
typedef struct cc_rgba_texture {
  const uint8_t* bytes;
  int32_t width;
  int32_t height;
} cc_rgba_texture;

CC_EXPORT int32_t cc_render_frame_rgba(cc_engine* engine, int64_t time_num,
                                       int32_t time_den, int32_t width,
                                       int32_t height, int32_t media_count,
                                       const char** utf8_keys,
                                       const char** utf8_paths,
                                       int32_t texture_count,
                                       const char** texture_keys,
                                       const cc_rgba_texture* textures,
                                       uint8_t** out_rgba);

// The v1 effect catalog as a JSON array (docs/03-features/effects.md). One
// definition in the engine; the Dart inspector renders from it.
CC_EXPORT int32_t cc_effect_catalog(cc_engine* engine, const char** out_json);

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

// --- Sequence audio (M3) ----------------------------------------------------
//
// One mixdown path serves monitoring, analysis and export, so preview loudness
// equals delivered loudness (docs/03-features/audio.md).

// Mixes [seconds] of the installed project snapshot starting at [start_sec]
// into interleaved stereo float32 at 48 kHz. Frees with cc_buffer_free.
// out_frames receives the frame count (samples per channel).
CC_EXPORT int32_t cc_mix_audio(cc_engine* engine, double start_sec,
                               double seconds, int32_t media_count,
                               const char** utf8_keys, const char** utf8_paths,
                               float** out_samples, int32_t* out_frames);

// Integrated loudness (LUFS), sample peak and true peak (dBFS/dBTP) of a mix
// window — "Analyze sequence loudness" (AUD-12).
CC_EXPORT int32_t cc_analyze_loudness(cc_engine* engine, double start_sec,
                                      double seconds, int32_t media_count,
                                      const char** utf8_keys,
                                      const char** utf8_paths,
                                      double* out_lufs, double* out_peak_db,
                                      double* out_true_peak_db);

// Peak of one asset's audio over a source range, for normalize (AUD-5).
CC_EXPORT int32_t cc_scan_audio_peak(cc_engine* engine, const char* utf8_path,
                                     double source_in_sec, double seconds,
                                     double* out_peak);

// Realtime monitoring of the sequence mix.
typedef struct cc_seq_player cc_seq_player;

CC_EXPORT cc_seq_player* cc_seq_player_create(void);
CC_EXPORT void cc_seq_player_destroy(cc_seq_player* player);
// Installs the document (JSON) plus the asset id → path map it mixes from.
CC_EXPORT int32_t cc_seq_player_set_document(cc_seq_player* player,
                                             const char* utf8_json,
                                             int32_t media_count,
                                             const char** utf8_keys,
                                             const char** utf8_paths);
CC_EXPORT int32_t cc_seq_player_start(cc_seq_player* player, double position_sec);
CC_EXPORT void cc_seq_player_stop(cc_seq_player* player);
CC_EXPORT void cc_seq_player_seek(cc_seq_player* player, double position_sec);
CC_EXPORT double cc_seq_player_position(cc_seq_player* player);
CC_EXPORT int32_t cc_seq_player_is_running(cc_seq_player* player);
CC_EXPORT void cc_seq_player_set_rate(cc_seq_player* player, double rate);
CC_EXPORT void cc_seq_player_levels(cc_seq_player* player, float* out_peak_l,
                                    float* out_peak_r);
// Newline-separated device names, default first (AUD-14). Do not free.
CC_EXPORT int32_t cc_audio_output_devices(cc_engine* engine, const char** out_names);
CC_EXPORT void cc_seq_player_set_output_device(cc_seq_player* player,
                                               const char* utf8_name);

#ifdef __cplusplus
}
#endif

#endif
