#include "flutter_window.h"

#include <shellapi.h>
#include <shlwapi.h>
#include <wincodec.h>

#include <chrono>
#include <cstring>
#include <optional>
#include <string>
#include <thread>
#include <vector>

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
  } else if (call.method_name() == "readClipboardMedia") {
    result->Success(ReadClipboardMedia());
  } else if (call.method_name() == "clipboardSequence") {
    result->Success(flutter::EncodableValue(
        static_cast<int64_t>(GetClipboardSequenceNumber())));
  } else {
    result->NotImplemented();
  }
}

namespace {

std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) return {};
  int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                 static_cast<int>(wide.size()), nullptr, 0,
                                 nullptr, nullptr);
  std::string out(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      out.data(), size, nullptr, nullptr);
  return out;
}

// Re-encodes clipboard bitmap bytes as PNG so the Dart side only ever handles
// one format. |bmp| is a complete BMP file image, which the WIC BMP decoder
// understands across the DIB variants apps actually put on the clipboard.
std::vector<uint8_t> EncodePng(const std::vector<uint8_t>& bmp) {
  std::vector<uint8_t> png;
  IWICImagingFactory* factory = nullptr;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&factory)))) {
    return png;
  }

  IWICStream* source = nullptr;
  IWICBitmapDecoder* decoder = nullptr;
  IWICBitmapFrameDecode* frame = nullptr;
  IStream* sink = nullptr;
  IWICBitmapEncoder* encoder = nullptr;
  IWICBitmapFrameEncode* out_frame = nullptr;

  if (SUCCEEDED(factory->CreateStream(&source)) &&
      SUCCEEDED(source->InitializeFromMemory(
          const_cast<uint8_t*>(bmp.data()),
          static_cast<DWORD>(bmp.size()))) &&
      SUCCEEDED(factory->CreateDecoderFromStream(
          source, nullptr, WICDecodeMetadataCacheOnLoad, &decoder)) &&
      SUCCEEDED(decoder->GetFrame(0, &frame)) &&
      SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &sink)) &&
      SUCCEEDED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr,
                                       &encoder)) &&
      SUCCEEDED(encoder->Initialize(sink, WICBitmapEncoderNoCache)) &&
      SUCCEEDED(encoder->CreateNewFrame(&out_frame, nullptr)) &&
      SUCCEEDED(out_frame->Initialize(nullptr)) &&
      SUCCEEDED(out_frame->WriteSource(frame, nullptr)) &&
      SUCCEEDED(out_frame->Commit()) && SUCCEEDED(encoder->Commit())) {
    HGLOBAL handle = nullptr;
    if (SUCCEEDED(GetHGlobalFromStream(sink, &handle)) && handle) {
      const auto size = GlobalSize(handle);
      if (const void* bytes = GlobalLock(handle)) {
        png.assign(static_cast<const uint8_t*>(bytes),
                   static_cast<const uint8_t*>(bytes) + size);
        GlobalUnlock(handle);
      }
    }
  }

  if (out_frame) out_frame->Release();
  if (encoder) encoder->Release();
  if (sink) sink->Release();
  if (frame) frame->Release();
  if (decoder) decoder->Release();
  if (source) source->Release();
  factory->Release();
  return png;
}

// Wraps a CF_DIB / CF_DIBV5 payload in a BMP file header so WIC can decode it.
std::vector<uint8_t> BmpFromDib(const uint8_t* dib, size_t size) {
  std::vector<uint8_t> bmp;
  if (size < sizeof(BITMAPINFOHEADER)) return bmp;
  BITMAPINFOHEADER header{};
  std::memcpy(&header, dib, sizeof(header));

  DWORD offset = static_cast<DWORD>(sizeof(BITMAPFILEHEADER)) + header.biSize;
  if (header.biCompression == BI_BITFIELDS &&
      header.biSize == sizeof(BITMAPINFOHEADER)) {
    offset += 12;  // The three colour masks sit between header and pixels.
  }
  offset += header.biClrUsed * sizeof(RGBQUAD);

  BITMAPFILEHEADER file{};
  file.bfType = 0x4D42;  // "BM"
  file.bfSize = static_cast<DWORD>(sizeof(file) + size);
  file.bfOffBits = offset;

  bmp.resize(sizeof(file) + size);
  std::memcpy(bmp.data(), &file, sizeof(file));
  std::memcpy(bmp.data() + sizeof(file), dib, size);
  return bmp;
}

}  // namespace

flutter::EncodableValue FlutterWindow::ReadClipboardMedia() {
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("sequence")] = flutter::EncodableValue(
      static_cast<int64_t>(GetClipboardSequenceNumber()));
  if (!OpenClipboard(GetHandle())) {
    return flutter::EncodableValue(payload);
  }

  // Files win over the bitmap: most apps offer both, and a real file is a
  // source the project can keep pointing at.
  flutter::EncodableList paths;
  if (HANDLE drop = GetClipboardData(CF_HDROP)) {
    auto files = static_cast<HDROP>(drop);
    const UINT count = DragQueryFileW(files, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count; i++) {
      const UINT length = DragQueryFileW(files, i, nullptr, 0);
      std::wstring path(static_cast<size_t>(length) + 1, L'\0');
      DragQueryFileW(files, i, path.data(), length + 1);
      path.resize(length);
      paths.push_back(flutter::EncodableValue(Utf8FromWide(path)));
    }
  }

  if (!paths.empty()) {
    payload[flutter::EncodableValue("paths")] =
        flutter::EncodableValue(std::move(paths));
  } else {
    std::vector<uint8_t> png;
    // Browsers and most image editors register a real PNG format; take those
    // bytes as they are rather than round-tripping them through a DIB.
    const UINT png_format = RegisterClipboardFormatW(L"PNG");
    if (HANDLE handle = png_format ? GetClipboardData(png_format) : nullptr) {
      const auto size = GlobalSize(handle);
      if (const void* bytes = GlobalLock(handle)) {
        png.assign(static_cast<const uint8_t*>(bytes),
                   static_cast<const uint8_t*>(bytes) + size);
        GlobalUnlock(handle);
      }
    }
    if (png.empty()) {
      HANDLE handle = GetClipboardData(CF_DIBV5);
      if (!handle) handle = GetClipboardData(CF_DIB);
      if (handle) {
        const auto size = GlobalSize(handle);
        if (const void* bytes = GlobalLock(handle)) {
          const auto bmp =
              BmpFromDib(static_cast<const uint8_t*>(bytes), size);
          GlobalUnlock(handle);
          if (!bmp.empty()) png = EncodePng(bmp);
        }
      }
    }
    if (!png.empty()) {
      payload[flutter::EncodableValue("image")] =
          flutter::EncodableValue(std::move(png));
      payload[flutter::EncodableValue("imageExtension")] =
          flutter::EncodableValue("png");
    }
  }

  if (HANDLE handle = GetClipboardData(CF_UNICODETEXT)) {
    if (const void* bytes = GlobalLock(handle)) {
      const std::string text = Utf8FromWide(static_cast<const wchar_t*>(bytes));
      GlobalUnlock(handle);
      if (!text.empty()) {
        payload[flutter::EncodableValue("text")] =
            flutter::EncodableValue(text);
      }
    }
  }

  CloseClipboard();
  return flutter::EncodableValue(payload);
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
