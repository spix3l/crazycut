#include "flutter_window.h"

#include <chrono>
#include <optional>
#include <thread>

#include "flutter/generated_plugin_registrant.h"
#include "flutter/plugin_registrar_windows.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  ConfigurePlaybackChannel();
  ConfigureSystemChannel();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (playback_texture_) {
    playback_texture_->Close();
    playback_texture_.reset();
  }
  UpdateSleepAssertion();  // active_exports_ is about to go away regardless

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // EXP-12: quitting mid-export asks first, and cancelling cleans up the
  // partial files before the app goes away. Mirrors
  // AppDelegate.applicationShouldTerminate on macOS.
  if (message == WM_CLOSE && !active_exports_.empty()) {
    std::wstring title = active_exports_.size() == 1
                              ? L"An export is still running"
                              : L"Exports are still running";
    std::wstring body = L"Quitting cancels them.\n\nCancel exports and quit?";
    int response = MessageBoxW(hwnd, body.c_str(), title.c_str(),
                               MB_YESNO | MB_ICONWARNING);
    if (response != IDYES) {
      return 0;
    }
    if (system_channel_) {
      system_channel_->InvokeMethod(
          "cancelExports", std::make_unique<flutter::EncodableValue>());
    }
    // Give the Dart side a moment to kill the workers and remove partials.
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    // Fall through to default handling, which destroys the window.
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

// MARK: - Playback channel

void FlutterWindow::ConfigurePlaybackChannel() {
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            flutter_controller_->engine()->GetRegistrarForPlugin(
                                "CrazyCutNativePlayback"));
  playback_texture_ =
      std::make_unique<NativePlaybackTexture>(registrar->texture_registrar());

  playback_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "dev.crazycut/playback",
          &flutter::StandardMethodCodec::GetInstance());
  playback_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandlePlaybackCall(call, std::move(result));
      });
}

void FlutterWindow::HandlePlaybackCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& method = call.method_name();
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

  if (method == "open") {
    std::string engine_lib, media;
    if (args) {
      if (auto it = args->find(flutter::EncodableValue("engineLib"));
          it != args->end()) {
        engine_lib = std::get<std::string>(it->second);
      }
      if (auto it = args->find(flutter::EncodableValue("media"));
          it != args->end()) {
        media = std::get<std::string>(it->second);
      }
    }
    if (engine_lib.empty() || media.empty()) {
      result->Error("bad_args", "open requires engineLib and media");
      return;
    }
    playback_texture_->Open(engine_lib, media, std::move(result));
  } else if (method == "play") {
    playback_texture_->Play();
    result->Success();
  } else if (method == "pause") {
    playback_texture_->Pause();
    result->Success();
  } else if (method == "seek") {
    double seconds = 0;
    if (args) {
      if (auto it = args->find(flutter::EncodableValue("seconds"));
          it != args->end()) {
        seconds = std::get<double>(it->second);
      }
    }
    playback_texture_->Seek(seconds);
    result->Success();
  } else if (method == "position") {
    result->Success(flutter::EncodableValue(playback_texture_->Position()));
  } else if (method == "isPlaying") {
    result->Success(flutter::EncodableValue(playback_texture_->IsPlaying()));
  } else if (method == "dispose") {
    playback_texture_->Close();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

// MARK: - System channel

void FlutterWindow::ConfigureSystemChannel() {
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            flutter_controller_->engine()->GetRegistrarForPlugin(
                                "CrazyCutSystem"));
  system_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "dev.crazycut/system",
          &flutter::StandardMethodCodec::GetInstance());
  system_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleSystemCall(call, std::move(result));
      });
}

void FlutterWindow::HandleSystemCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "setActiveExports") {
    active_exports_.clear();
    if (const auto* list = std::get_if<flutter::EncodableList>(call.arguments())) {
      for (const auto& item : *list) {
        if (const auto* s = std::get_if<std::string>(&item)) {
          active_exports_.push_back(*s);
        }
      }
    }
    UpdateSleepAssertion();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

/// Keeps the machine awake while an export runs; a laptop that sleeps
/// halfway through a render is a lost render.
void FlutterWindow::UpdateSleepAssertion() {
  const bool should_be_active = !active_exports_.empty();
  if (should_be_active == sleep_assertion_active_) return;

  if (should_be_active) {
    SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED |
                            ES_AWAYMODE_REQUIRED);
  } else {
    SetThreadExecutionState(ES_CONTINUOUS);
  }
  sleep_assertion_active_ = should_be_active;
}
