#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <vector>

#include "native_playback_texture.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // dev.crazycut/playback: mirrors AppDelegate.swift's playback channel.
  void ConfigurePlaybackChannel();
  void HandlePlaybackCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // dev.crazycut/system: quit-with-exports-running guard (EXP-12) and the
  // sleep-prevention assertion while an export runs.
  void ConfigureSystemChannel();
  void HandleSystemCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void UpdateSleepAssertion();

  // IMP-1: reads files, a bitmap or text off the system clipboard so a paste
  // can import media. Mirrors AppDelegate.swift's Clipboard helper.
  flutter::EncodableValue ReadClipboardMedia();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<NativePlaybackTexture> playback_texture_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      playback_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      system_channel_;

  std::vector<std::string> active_exports_;
  bool sleep_assertion_active_ = false;
  bool close_pending_confirmation_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
