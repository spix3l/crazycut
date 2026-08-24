#ifndef RUNNER_NATIVE_PLAYBACK_TEXTURE_H_
#define RUNNER_NATIVE_PLAYBACK_TEXTURE_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>
#include <windows.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Windows counterpart of macOS's NativePlaybackTexture.swift: loads the
// engine's playback symbols with LoadLibrary/GetProcAddress (the dlopen
// equivalent) and feeds decoded RGBA frames to a Flutter pixel-buffer
// texture on a background thread.
//
// NOTE: written to mirror the macOS implementation's contract exactly, but
// has not been run on Windows (no Windows machine available in development).
// See README.md "Windows native playback" for what to verify first.
class NativePlaybackTexture {
 public:
  explicit NativePlaybackTexture(flutter::TextureRegistrar* texture_registrar);
  ~NativePlaybackTexture();

  // Opens `media_path` using the engine at `engine_lib_path`. On success,
  // returns the registered texture id, duration (seconds) and fps via the
  // FlutterMethodResult, matching the macOS "open" response shape.
  void Open(const std::string& engine_lib_path, const std::string& media_path,
            std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void Play();
  void Pause();
  void Seek(double seconds);
  double Position();
  bool IsPlaying();
  void Close();

 private:
  using CreateFn = void* (*)(const char*);
  using DestroyFn = void (*)(void*);
  using StartFn = int32_t (*)(void*);
  using PauseResumeFn = void (*)(void*);
  using IsPlayingFn = int32_t (*)(void*);
  using SeekFn = int32_t (*)(void*, double);
  using PositionFn = double (*)(void*);
  using DurationFn = double (*)(void*);
  using FpsFn = double (*)(void*);
  using LockFrameFn = const uint8_t* (*)(void*, int32_t*, int32_t*);
  using UnlockFrameFn = void (*)(void*);
  using ReachedEndFn = int32_t (*)(void*);

  bool LoadSymbols();
  double DisplayFrameRate();
  void PresentLoop();
  const FlutterDesktopPixelBuffer* CopyPixelBuffer(size_t width, size_t height);
  bool ReachedEnd();

  flutter::TextureRegistrar* texture_registrar_;
  std::unique_ptr<flutter::TextureVariant> texture_;
  int64_t texture_id_ = -1;

  HMODULE lib_handle_ = nullptr;
  void* session_ = nullptr;

  CreateFn f_create_ = nullptr;
  DestroyFn f_destroy_ = nullptr;
  StartFn f_start_ = nullptr;
  PauseResumeFn f_pause_ = nullptr;
  PauseResumeFn f_resume_ = nullptr;
  IsPlayingFn f_is_playing_ = nullptr;
  SeekFn f_seek_ = nullptr;
  PositionFn f_position_ = nullptr;
  DurationFn f_duration_ = nullptr;
  FpsFn f_fps_ = nullptr;
  LockFrameFn f_lock_frame_ = nullptr;
  UnlockFrameFn f_unlock_frame_ = nullptr;
  ReachedEndFn f_reached_end_ = nullptr;

  // Double-buffered RGBA frame storage. `front_index_` is only ever written
  // to by the presenter thread by swapping to the buffer it just finished
  // filling, so CopyPixelBuffer (invoked on the engine's raster thread) can
  // read the front buffer without holding a lock in the steady state.
  struct FrameBuffer {
    std::vector<uint8_t> data;
    size_t width = 0;
    size_t height = 0;
  };
  FrameBuffer buffers_[2];
  std::atomic<int> front_index_{0};
  std::mutex resize_mutex_;
  FlutterDesktopPixelBuffer pixel_buffer_{};

  std::thread present_thread_;
  std::atomic<bool> running_{false};
};

#endif  // RUNNER_NATIVE_PLAYBACK_TEXTURE_H_
