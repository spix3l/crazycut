#include "native_playback_texture.h"

#include <algorithm>

namespace {

template <typename T>
T LoadSym(HMODULE module, const char* name) {
  return reinterpret_cast<T>(GetProcAddress(module, name));
}

}  // namespace

NativePlaybackTexture::NativePlaybackTexture(
    flutter::TextureRegistrar* texture_registrar)
    : texture_registrar_(texture_registrar) {}

NativePlaybackTexture::~NativePlaybackTexture() { Close(); }

bool NativePlaybackTexture::LoadSymbols() {
  f_create_ = LoadSym<CreateFn>(lib_handle_, "cc_playback_create");
  f_destroy_ = LoadSym<DestroyFn>(lib_handle_, "cc_playback_destroy");
  f_start_ = LoadSym<StartFn>(lib_handle_, "cc_playback_start");
  f_pause_ = LoadSym<PauseResumeFn>(lib_handle_, "cc_playback_pause");
  f_resume_ = LoadSym<PauseResumeFn>(lib_handle_, "cc_playback_resume");
  f_is_playing_ = LoadSym<IsPlayingFn>(lib_handle_, "cc_playback_is_playing");
  f_seek_ = LoadSym<SeekFn>(lib_handle_, "cc_playback_seek");
  f_position_ = LoadSym<PositionFn>(lib_handle_, "cc_playback_position");
  f_duration_ = LoadSym<DurationFn>(lib_handle_, "cc_playback_duration");
  f_fps_ = LoadSym<FpsFn>(lib_handle_, "cc_playback_fps");
  f_lock_frame_ = LoadSym<LockFrameFn>(lib_handle_, "cc_playback_lock_frame");
  f_unlock_frame_ =
      LoadSym<UnlockFrameFn>(lib_handle_, "cc_playback_unlock_frame");
  f_reached_end_ =
      LoadSym<ReachedEndFn>(lib_handle_, "cc_playback_reached_end");
  return f_create_ && f_destroy_ && f_start_;
}

void NativePlaybackTexture::Open(
    const std::string& engine_lib_path, const std::string& media_path,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  Close();

  lib_handle_ = LoadLibraryA(engine_lib_path.c_str());
  if (!lib_handle_) {
    result->Error("dlopen_failed",
                   "LoadLibrary failed with error " +
                       std::to_string(GetLastError()));
    return;
  }

  if (!LoadSymbols()) {
    result->Error("abi_error",
                   "engine missing playback symbols \xe2\x80\x94 rebuild engine");
    return;
  }

  session_ = f_create_(media_path.c_str());
  if (!session_) {
    result->Error("open_failed", "could not open media for playback");
    return;
  }

  texture_ = std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
      [this](size_t width, size_t height) -> const FlutterDesktopPixelBuffer* {
        return CopyPixelBuffer(width, height);
      }));
  texture_id_ = texture_registrar_->RegisterTexture(texture_.get());
  if (texture_id_ < 0) {
    result->Error("register_failed", "texture registration failed");
    return;
  }

  f_start_(session_);

  running_ = true;
  present_thread_ = std::thread([this] { PresentLoop(); });

  flutter::EncodableMap response{
      {flutter::EncodableValue("textureId"),
       flutter::EncodableValue(texture_id_)},
      {flutter::EncodableValue("duration"),
       flutter::EncodableValue(f_duration_ ? f_duration_(session_) : 0.0)},
      {flutter::EncodableValue("fps"), flutter::EncodableValue(DisplayFrameRate())},
  };
  result->Success(flutter::EncodableValue(response));
}

double NativePlaybackTexture::DisplayFrameRate() {
  double fps = f_fps_ ? f_fps_(session_) : 30.0;
  return std::min(std::max(fps, 10.0), 60.0);
}

void NativePlaybackTexture::PresentLoop() {
  const auto interval =
      std::chrono::duration<double>(1.0 / DisplayFrameRate());
  while (running_.load()) {
    if (session_ && f_lock_frame_ && f_unlock_frame_) {
      int32_t width = 0, height = 0;
      const uint8_t* pixels = f_lock_frame_(session_, &width, &height);
      if (pixels && width > 0 && height > 0) {
        int back = 1 - front_index_.load();
        auto& buf = buffers_[back];
        const size_t needed = static_cast<size_t>(width) * height * 4;
        if (buf.data.size() != needed) {
          std::lock_guard<std::mutex> lock(resize_mutex_);
          buf.data.resize(needed);
        }
        buf.width = static_cast<size_t>(width);
        buf.height = static_cast<size_t>(height);
        std::copy(pixels, pixels + needed, buf.data.begin());
        front_index_.store(back);
        texture_registrar_->MarkTextureFrameAvailable(texture_id_);
      }
      f_unlock_frame_(session_);
    }
    std::this_thread::sleep_for(
        std::chrono::duration_cast<std::chrono::milliseconds>(interval));
  }
}

const FlutterDesktopPixelBuffer* NativePlaybackTexture::CopyPixelBuffer(
    size_t /*width*/, size_t /*height*/) {
  auto& buf = buffers_[front_index_.load()];
  if (buf.data.empty()) return nullptr;
  pixel_buffer_.buffer = buf.data.data();
  pixel_buffer_.width = buf.width;
  pixel_buffer_.height = buf.height;
  return &pixel_buffer_;
}

bool NativePlaybackTexture::ReachedEnd() {
  if (!session_ || !f_reached_end_) return false;
  return f_reached_end_(session_) == 1;
}

void NativePlaybackTexture::Play() {
  if (!session_) return;
  if (f_is_playing_ && f_is_playing_(session_) == 0) {
    if (ReachedEnd() && f_seek_) f_seek_(session_, 0.0);
    if (f_resume_) f_resume_(session_);
  } else if (f_start_) {
    f_start_(session_);
  }
}

void NativePlaybackTexture::Pause() {
  if (session_ && f_pause_) f_pause_(session_);
}

void NativePlaybackTexture::Seek(double seconds) {
  if (session_ && f_seek_) f_seek_(session_, seconds);
}

double NativePlaybackTexture::Position() {
  if (!session_ || !f_position_) return 0;
  return f_position_(session_);
}

bool NativePlaybackTexture::IsPlaying() {
  if (!session_ || !f_is_playing_) return false;
  return f_is_playing_(session_) == 1;
}

void NativePlaybackTexture::Close() {
  running_ = false;
  if (present_thread_.joinable()) present_thread_.join();

  if (session_) {
    if (f_pause_) f_pause_(session_);
    if (f_destroy_) f_destroy_(session_);
  }
  session_ = nullptr;

  if (texture_id_ >= 0) {
    texture_registrar_->UnregisterTexture(texture_id_);
    texture_id_ = -1;
  }
  texture_.reset();

  buffers_[0] = FrameBuffer{};
  buffers_[1] = FrameBuffer{};
  front_index_ = 0;

  if (lib_handle_) {
    FreeLibrary(lib_handle_);
    lib_handle_ = nullptr;
  }
}
