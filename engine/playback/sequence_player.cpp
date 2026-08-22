#include "playback/sequence_player.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <thread>

// miniaudio's implementation is compiled once, in playback/player.cpp.
#include <miniaudio.h>

#include "audio/mixer.h"
#include "core/log.h"

namespace cc {
namespace {

constexpr int kChannels = 2;
// Enough buffered audio to ride out a slow mix chunk without a dropout, small
// enough that a seek is heard immediately.
constexpr double kRingSeconds = 0.75;
constexpr double kChunkSeconds = 0.10;

// Single-producer/single-consumer float ring. The mix thread writes, the
// device callback reads; neither ever blocks the other.
class Ring {
 public:
  explicit Ring(size_t capacity) : buf_(capacity, 0.f) {}

  size_t writable() const { return buf_.size() - size(); }
  size_t size() const { return write_.load() - read_.load(); }

  size_t write(const float* data, size_t count) {
    count = std::min(count, writable());
    const size_t w = write_.load();
    for (size_t i = 0; i < count; ++i) buf_[(w + i) % buf_.size()] = data[i];
    write_.store(w + count);
    return count;
  }

  size_t read(float* out, size_t count) {
    count = std::min(count, size());
    const size_t r = read_.load();
    for (size_t i = 0; i < count; ++i) out[i] = buf_[(r + i) % buf_.size()];
    read_.store(r + count);
    return count;
  }

  void clear() { read_.store(write_.load()); }

 private:
  std::vector<float> buf_;
  std::atomic<size_t> write_{0};
  std::atomic<size_t> read_{0};
};

}  // namespace

struct SequencePlayer::Impl {
  // --- Shared state (guarded) ---
  std::mutex docMutex;
  nlohmann::json document;
  std::map<std::string, std::string> mediaPaths;
  MasterSettings master;
  std::string deviceName;

  // --- Control ---
  std::atomic<bool> exiting{false};
  std::atomic<bool> playing{false};
  std::atomic<double> rate{1.0};
  std::atomic<uint64_t> generation{0};
  std::atomic<double> seekRequest{-1.0};

  // --- Clock ---
  mutable std::mutex clockMutex;
  double basePosition = 0;      // sequence seconds at the start of this run
  int64_t framesConsumed = 0;   // frames the device has taken since then

  Ring ring{static_cast<size_t>(kRingSeconds * kMixSampleRate) * kChannels};
  std::thread mixThread;

  ma_device device{};
  bool deviceReady = false;

  std::atomic<float> peakL{0.f};
  std::atomic<float> peakR{0.f};

  static void dataCallback(ma_device* device, void* output, const void*,
                           const uint32_t frameCount) {
    auto* self = static_cast<Impl*>(device->pUserData);
    if (!self) return;
    auto* dst = static_cast<float*>(output);
    const size_t want = static_cast<size_t>(frameCount) * kChannels;
    const size_t got = self->ring.read(dst, want);
    if (got < want) std::memset(dst + got, 0, (want - got) * sizeof(float));

    float pl = 0.f, pr = 0.f;
    for (size_t i = 0; i + 1 < got; i += 2) {
      pl = std::max(pl, std::fabs(dst[i]));
      pr = std::max(pr, std::fabs(dst[i + 1]));
    }
    self->peakL.store(pl);
    self->peakR.store(pr);

    if (self->playing.load()) {
      std::lock_guard<std::mutex> lock(self->clockMutex);
      self->framesConsumed += static_cast<int64_t>(got / kChannels);
    }
  }

  double positionLocked() const {
    return basePosition +
           static_cast<double>(framesConsumed) / kMixSampleRate *
               std::fabs(rate.load());
  }

  // Sequence position the mixer should render next; tracked by the mix thread.
  void mixMain() {
    double cursor = 0;
    uint64_t lastGen = ~0ull;

    while (!exiting.load()) {
      const uint64_t gen = generation.load();
      if (gen != lastGen) {
        lastGen = gen;
        const double wanted = seekRequest.load();
        ring.clear();
        {
          std::lock_guard<std::mutex> lock(clockMutex);
          basePosition = wanted >= 0 ? wanted : basePosition;
          framesConsumed = 0;
        }
        cursor = wanted >= 0 ? wanted : cursor;
      }
      if (!playing.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        continue;
      }

      const size_t chunkFrames =
          static_cast<size_t>(kChunkSeconds * kMixSampleRate);
      if (ring.writable() < chunkFrames * kChannels) {
        std::this_thread::sleep_for(std::chrono::milliseconds(4));
        continue;
      }

      AudioBuffer chunk;
      const double speed = std::fabs(rate.load());
      // Shuttle past 2× monitors silence rather than a chipmunk artefact.
      const bool mute = speed > 2.0 || rate.load() < 0;
      if (mute) {
        chunk.resizeFrames(chunkFrames);
      } else {
        nlohmann::json doc;
        std::map<std::string, std::string> paths;
        MasterSettings settings;
        {
          std::lock_guard<std::mutex> lock(docMutex);
          doc = document;
          paths = mediaPaths;
          settings = master;
        }
        if (mixTimeline(doc, paths, cursor, kChunkSeconds * speed,
                        kMixSampleRate, settings, &chunk) != Error::None) {
          chunk.resizeFrames(chunkFrames);
        }
        // Varispeed: resample the mixed window down to one chunk of output.
        if (speed != 1.0 && chunk.frames() > 0) {
          AudioBuffer scaled;
          scaled.resizeFrames(chunkFrames);
          for (size_t i = 0; i < chunkFrames; ++i) {
            const size_t src = static_cast<size_t>(i * speed);
            if (src * 2 + 1 >= chunk.samples.size()) break;
            scaled.samples[i * 2] = chunk.samples[src * 2];
            scaled.samples[i * 2 + 1] = chunk.samples[src * 2 + 1];
          }
          chunk = std::move(scaled);
        }
      }
      if (chunk.frames() < chunkFrames) chunk.samples.resize(chunkFrames * 2, 0.f);

      size_t written = 0;
      while (written < chunk.samples.size() && !exiting.load() &&
             generation.load() == lastGen) {
        written += ring.write(chunk.samples.data() + written,
                              chunk.samples.size() - written);
        if (written < chunk.samples.size()) {
          std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
      }
      if (generation.load() == lastGen) cursor += kChunkSeconds * speed;
    }
  }

  Error openDevice() {
    if (deviceReady) return Error::None;
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = kChannels;
    cfg.sampleRate = kMixSampleRate;
    cfg.periodSizeInFrames = 480;  // 10 ms
    cfg.dataCallback = &Impl::dataCallback;
    cfg.pUserData = this;

    ma_device_id chosen{};
    bool haveChosen = false;
    if (!deviceName.empty()) {
      ma_context context;
      if (ma_context_init(nullptr, 0, nullptr, &context) == MA_SUCCESS) {
        ma_device_info* infos = nullptr;
        ma_uint32 count = 0;
        if (ma_context_get_devices(&context, &infos, &count, nullptr,
                                   nullptr) == MA_SUCCESS) {
          for (ma_uint32 i = 0; i < count; ++i) {
            if (deviceName == infos[i].name) {
              chosen = infos[i].id;
              haveChosen = true;
              break;
            }
          }
        }
        ma_context_uninit(&context);
      }
    }
    if (haveChosen) cfg.playback.pDeviceID = &chosen;

    if (ma_device_init(nullptr, &cfg, &device) != MA_SUCCESS) {
      CC_LOG_WARN("no audio output device; preview runs silent");
      return Error::None;  // silent monitoring is degraded, not fatal
    }
    if (ma_device_start(&device) != MA_SUCCESS) {
      ma_device_uninit(&device);
      return Error::None;
    }
    deviceReady = true;
    return Error::None;
  }

  void closeDevice() {
    if (!deviceReady) return;
    ma_device_uninit(&device);
    deviceReady = false;
  }
};

SequencePlayer::SequencePlayer() : impl_(std::make_unique<Impl>()) {
  impl_->mixThread = std::thread([p = impl_.get()] { p->mixMain(); });
}

SequencePlayer::~SequencePlayer() {
  impl_->exiting.store(true);
  impl_->playing.store(false);
  if (impl_->mixThread.joinable()) impl_->mixThread.join();
  impl_->closeDevice();
}

void SequencePlayer::setDocument(
    const nlohmann::json& document,
    const std::map<std::string, std::string>& mediaPaths) {
  std::lock_guard<std::mutex> lock(impl_->docMutex);
  impl_->document = document;
  impl_->mediaPaths = mediaPaths;
  impl_->master = masterFromDocument(document);
}

Error SequencePlayer::start(double positionSec) {
  impl_->seekRequest.store(std::max(0.0, positionSec));
  impl_->generation.fetch_add(1);
  impl_->playing.store(true);
  return impl_->openDevice();
}

void SequencePlayer::stop() {
  impl_->playing.store(false);
  std::lock_guard<std::mutex> lock(impl_->clockMutex);
  impl_->basePosition = impl_->positionLocked();
  impl_->framesConsumed = 0;
}

void SequencePlayer::seek(double positionSec) {
  impl_->seekRequest.store(std::max(0.0, positionSec));
  impl_->generation.fetch_add(1);
}

double SequencePlayer::position() const {
  std::lock_guard<std::mutex> lock(impl_->clockMutex);
  return impl_->positionLocked();
}

bool SequencePlayer::running() const { return impl_->playing.load(); }

void SequencePlayer::setRate(double rate) { impl_->rate.store(rate); }

void SequencePlayer::levels(float* peakL, float* peakR) const {
  if (peakL) *peakL = impl_->peakL.load();
  if (peakR) *peakR = impl_->peakR.load();
}

std::vector<std::string> SequencePlayer::outputDevices() {
  std::vector<std::string> names;
  ma_context context;
  if (ma_context_init(nullptr, 0, nullptr, &context) != MA_SUCCESS) return names;
  ma_device_info* infos = nullptr;
  ma_uint32 count = 0;
  if (ma_context_get_devices(&context, &infos, &count, nullptr, nullptr) ==
      MA_SUCCESS) {
    for (ma_uint32 i = 0; i < count; ++i) {
      if (infos[i].isDefault) {
        names.insert(names.begin(), infos[i].name);
      } else {
        names.emplace_back(infos[i].name);
      }
    }
  }
  ma_context_uninit(&context);
  return names;
}

void SequencePlayer::setOutputDevice(const std::string& name) {
  std::lock_guard<std::mutex> lock(impl_->docMutex);
  if (impl_->deviceName == name) return;
  impl_->deviceName = name;
  impl_->closeDevice();  // reopened on the next start()
}

}  // namespace cc
