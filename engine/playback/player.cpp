#include "playback/player.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#define MINIAUDIO_IMPLEMENTATION
#include <miniaudio.h>

#include "core/log.h"
#include "core/result.h"

namespace cc {

namespace {

constexpr int kSampleRate = 48000;
constexpr int kChannels = 2;
constexpr int kRingFrames = 1 << 16;
constexpr size_t kMaxQueuedPackets = 128;

class SpscRing {
 public:
  explicit SpscRing(size_t capacityFloats) : buf_(capacityFloats, 0.0f) {}

  size_t write(const float* data, size_t count) {
    const size_t space = capacity() - size();
    if (count > space) count = space;
    for (size_t i = 0; i < count; ++i) {
      buf_[writePos_ % buf_.size()] = data[i];
      ++writePos_;
    }
    return count;
  }

  size_t read(float* out, size_t count) {
    const size_t available = size();
    if (count > available) count = available;
    for (size_t i = 0; i < count; ++i) {
      out[i] = buf_[readPos_ % buf_.size()];
      ++readPos_;
    }
    return count;
  }

  void clear() { writePos_.store(readPos_.load()); }

 private:
  size_t capacity() const { return buf_.size(); }
  size_t size() const { return writePos_ - readPos_; }

  std::vector<float> buf_;
  std::atomic<uint64_t> writePos_{0};
  std::atomic<uint64_t> readPos_{0};
};

struct PacketQueue {
  std::deque<AVPacket*> items;
  std::mutex mutex;

  void push(AVPacket* pkt) {
    std::lock_guard<std::mutex> lock(mutex);
    items.push_back(pkt);
  }

  AVPacket* tryPop() {
    std::lock_guard<std::mutex> lock(mutex);
    if (items.empty()) return nullptr;
    AVPacket* pkt = items.front();
    items.pop_front();
    return pkt;
  }

  size_t size() {
    std::lock_guard<std::mutex> lock(mutex);
    return items.size();
  }

  void clear() {
    std::lock_guard<std::mutex> lock(mutex);
    while (!items.empty()) {
      AVPacket* pkt = items.front();
      items.pop_front();
      av_packet_free(&pkt);
    }
  }
};

struct DecodedRgba {
  int w = 0;
  int h = 0;
  double ptsSec = 0;
  std::vector<uint8_t> pixels;
};

}  // namespace

struct PlaybackSession::Impl {
  std::string path;
  int videoWidth = 960;

  AVFormatContext* format = nullptr;
  AVCodecContext* vDec = nullptr;
  AVCodecContext* aDec = nullptr;
  SwsContext* swsV = nullptr;
  SwrContext* swrA = nullptr;
  int vIdx = -1;
  int aIdx = -1;
  AVStream* vStream = nullptr;
  AVStream* aStream = nullptr;
  AVRational vFps{30, 1};
  double durationSec = 0;

  std::thread demuxThread;
  std::thread audioThread;
  std::thread videoThread;
  std::atomic<bool> exiting{false};

  std::atomic<bool> paused{false};
  std::atomic<int> generation{0};
  std::atomic<bool> videoEof{false};
  std::atomic<bool> audioEof{false};

  PacketQueue vPackets;
  PacketQueue aPackets;
  std::atomic<bool> demuxFlushSent{false};

  // Seeking used to reposition the format context and flush both codecs from
  // whichever thread called seek(), while the demux and decode threads were
  // using them — a data race that crashed inside libavcodec. Now each ffmpeg
  // object has exactly one owning thread: `format` belongs to demuxMain,
  // `vDec` to videoMain, `aDec` to audioMain, and seek() only posts a request.
  std::atomic<double> seekRequest{-1.0};

  mutable std::mutex clockMutex;
  bool audioClockValid = false;
  double basePosition = 0;
  int64_t framesPlayed = 0;
  std::chrono::steady_clock::time_point wallAnchor{};
  double wallAccumulated = 0;

  ma_device device{};
  bool deviceRunning = false;
  SpscRing ring{kRingFrames * kChannels};

  std::mutex frameMutex;
  std::shared_ptr<DecodedRgba> latestFrame;

  static void audioCallback(ma_device* device, void* output,
                            const void* input, const uint32_t frameCount) {
    (void)input;
    auto* p = static_cast<Impl*>(device->pUserData);
    if (!p) return;
    auto* dst = static_cast<float*>(output);
    const size_t want = static_cast<size_t>(frameCount) * kChannels;
    const size_t got = p->ring.read(dst, want);
    if (got < want) {
      std::memset(dst + got, 0, (want - got) * sizeof(float));
    }
    p->framesPlayed += got / kChannels;
  }

  double clockSeconds() const {
    std::lock_guard<std::mutex> lock(clockMutex);
    if (audioClockValid) {
      return basePosition + static_cast<double>(framesPlayed) / kSampleRate;
    }
    if (paused.load()) {
      return basePosition + wallAccumulated;
    }
    const auto elapsed = std::chrono::duration<double>(
                             std::chrono::steady_clock::now() - wallAnchor)
                             .count();
    return basePosition + wallAccumulated + elapsed;
  }

  Error openInput() {
    int ret = avformat_open_input(&format, path.c_str(), nullptr, nullptr);
    if (ret < 0) return Error::MediaOpenFailed;
    ret = avformat_find_stream_info(format, nullptr);
    if (ret < 0) return Error::MediaOpenFailed;

    vIdx = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    aIdx = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);

    if (format->duration > 0) {
      durationSec = static_cast<double>(format->duration) / AV_TIME_BASE;
    }
    if (vIdx >= 0) {
      vStream = format->streams[vIdx];
      const AVCodec* dec = avcodec_find_decoder(vStream->codecpar->codec_id);
      if (!dec) return Error::MediaDecodeFailed;
      vDec = avcodec_alloc_context3(dec);
      avcodec_parameters_to_context(vDec, vStream->codecpar);
      if (avcodec_open2(vDec, dec, nullptr) < 0) return Error::MediaDecodeFailed;
      if (vStream->avg_frame_rate.num > 0) {
        vFps = vStream->avg_frame_rate;
      } else if (vDec->framerate.num > 0) {
        vFps = vDec->framerate;
      }
    }
    if (aIdx >= 0) {
      aStream = format->streams[aIdx];
      const AVCodec* dec = avcodec_find_decoder(aStream->codecpar->codec_id);
      if (!dec) return Error::MediaDecodeFailed;
      aDec = avcodec_alloc_context3(dec);
      avcodec_parameters_to_context(aDec, aStream->codecpar);
      if (avcodec_open2(aDec, dec, nullptr) < 0) return Error::MediaDecodeFailed;
    }
    if (vIdx < 0 && aIdx < 0) return Error::MediaNoStream;
    return Error::None;
  }

  void demuxMain() {
    AVPacket* pkt = av_packet_alloc();
    uint64_t lastGen = 0;
    while (!exiting.load()) {
      if (generation.load() != lastGen) {
        lastGen = generation.load();
        vPackets.clear();
        aPackets.clear();
        demuxFlushSent.store(false);
      }
      // Handled before the pause check: seeking while paused must still move
      // the read position so the next resume plays from there.
      const double wanted = seekRequest.exchange(-1.0);
      if (wanted >= 0.0) {
        const int streamIdx = vIdx >= 0 ? vIdx : aIdx;
        const AVStream* stream = vIdx >= 0 ? vStream : aStream;
        if (stream) {
          const int64_t target =
              static_cast<int64_t>(wanted / av_q2d(stream->time_base));
          avformat_seek_file(format, streamIdx, INT64_MIN, target, target, 0);
        } else {
          av_seek_frame(format, -1, static_cast<int64_t>(wanted * AV_TIME_BASE),
                        AVSEEK_FLAG_BACKWARD);
        }
        vPackets.clear();
        aPackets.clear();
        demuxFlushSent.store(false);
      }
      if (paused.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        continue;
      }
      if (demuxFlushSent.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        continue;
      }
      int ret = av_read_frame(format, pkt);
      if (ret < 0) {
        if (!demuxFlushSent.exchange(true)) {
          vPackets.push(nullptr);
          aPackets.push(nullptr);
        }
        continue;
      }
      if (pkt->stream_index == vIdx) {
        while (!exiting.load() && vPackets.size() >= kMaxQueuedPackets &&
               generation.load() == lastGen) {
          std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        vPackets.push(pkt);
      } else if (pkt->stream_index == aIdx) {
        while (!exiting.load() && aPackets.size() >= kMaxQueuedPackets &&
               generation.load() == lastGen) {
          std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        aPackets.push(pkt);
      } else {
        av_packet_unref(pkt);
      }
      pkt = av_packet_alloc();
    }
    av_packet_free(&pkt);
  }

  void audioMain() {
    AVFrame* frame = av_frame_alloc();
    std::vector<uint8_t> convBuf;
    uint64_t lastGen = 0;
    while (!exiting.load()) {
      if (generation.load() != lastGen) {
        lastGen = generation.load();
        audioEof.store(false);
        if (aDec) avcodec_flush_buffers(aDec);  // this thread owns aDec
      }
      AVPacket* pkt = aPackets.tryPop();
      if (!pkt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(3));
        continue;
      }
      if (isSentinel(pkt)) {
        av_packet_free(&pkt);
        avcodec_send_packet(aDec, nullptr);
        bool gotAny = false;
        while (true) {
          const int r = avcodec_receive_frame(aDec, frame);
          if (r < 0) break;
          gotAny = pushResampled(frame, &convBuf);
          av_frame_unref(frame);
        }
        (void)gotAny;
        audioEof.store(true);
        continue;
      }
      if (avcodec_send_packet(aDec, pkt) == 0) {
        while (avcodec_receive_frame(aDec, frame) == 0) {
          pushResampled(frame, &convBuf);
          av_frame_unref(frame);
        }
      }
      av_packet_free(&pkt);
    }
    av_frame_free(&frame);
  }

  static AVPacket* sentinel() { return reinterpret_cast<AVPacket*>(1); }
  static bool isSentinel(AVPacket* pkt) { return pkt == sentinel(); }

  bool pushResampled(AVFrame* frame, std::vector<uint8_t>* convBuf) {
    const int maxOut = frame->nb_samples * 2 + 64;
    convBuf->resize(static_cast<size_t>(maxOut) * kChannels * sizeof(float));
    uint8_t* outs[1] = {convBuf->data()};
    const int n = swr_convert(swrA, outs, frame->nb_samples,
                              const_cast<const uint8_t**>(frame->data),
                              frame->nb_samples);
    if (n <= 0) return false;
    const float* floats = reinterpret_cast<const float*>(convBuf->data());
    const size_t toWrite = static_cast<size_t>(n) * kChannels;
    size_t offset = 0;
    while (offset < toWrite && !exiting.load()) {
      const size_t written = ring.write(floats + offset, toWrite - offset);
      offset += written;
      if (written == 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(4));
      }
    }
    return true;
  }

  void videoMain() {
    AVPacket* pkt = av_packet_alloc();
    AVFrame* frame = av_frame_alloc();
    DecodedRgba pending;
    DecodedRgba next;
    bool haveNext = false;
    uint64_t lastGen = 0;
    const double frameDur =
        vFps.num > 0 ? av_q2d(av_inv_q(vFps)) : 1.0 / 30.0;

    while (!exiting.load()) {
      if (generation.load() != lastGen) {
        lastGen = generation.load();
        haveNext = false;
        videoEof.store(false);
        if (vDec) avcodec_flush_buffers(vDec);  // this thread owns vDec
        std::lock_guard<std::mutex> lock(frameMutex);
        latestFrame.reset();
      }
      if (!haveNext) {
        AVPacket* qpkt = vPackets.tryPop();
        if (!qpkt) {
          std::this_thread::sleep_for(std::chrono::milliseconds(3));
          continue;
        }
        if (isSentinel(qpkt)) {
          av_packet_free(&qpkt);
          videoEof.store(true);
          std::this_thread::sleep_for(std::chrono::milliseconds(50));
          continue;
        }
        bool produced = false;
        if (avcodec_send_packet(vDec, qpkt) == 0) {
          while (avcodec_receive_frame(vDec, frame) == 0) {
            if (convertToRgba(frame, &pending)) produced = true;
            av_frame_unref(frame);
          }
        }
        av_packet_free(&qpkt);
        if (produced) {
          next = pending;
          haveNext = true;
        }
        continue;
      }

      while (!exiting.load() && !paused.load() &&
             generation.load() == lastGen) {
        if (clockSeconds() >= next.ptsSec - frameDur * 0.25) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
      }
      if (exiting.load() || generation.load() != lastGen || paused.load())
        continue;

      {
        std::lock_guard<std::mutex> lock(frameMutex);
        latestFrame = std::make_shared<DecodedRgba>(next);
      }
      haveNext = false;
    }
    av_packet_free(&pkt);
    av_frame_free(&frame);
  }

  bool convertToRgba(AVFrame* frame, DecodedRgba* out) {
    const int srcW = frame->width;
    const int srcH = frame->height;
    int dstW = videoWidth > 0 ? videoWidth : srcW;
    dstW -= dstW % 2;
    int dstH =
        static_cast<int>(std::llround(static_cast<double>(srcH) * dstW / srcW));
    dstH -= dstH % 2;
    if (dstW <= 0 || dstH <= 0) return false;

    swsV = sws_getCachedContext(swsV, srcW, srcH,
                                static_cast<AVPixelFormat>(frame->format),
                                dstW, dstH, AV_PIX_FMT_RGBA, SWS_BILINEAR,
                                nullptr, nullptr, nullptr);
    if (!swsV) return false;

    out->w = dstW;
    out->h = dstH;
    out->ptsSec = frame->pts != AV_NOPTS_VALUE
                      ? static_cast<double>(frame->pts) *
                            av_q2d(vStream->time_base)
                      : 0;
    out->pixels.assign(static_cast<size_t>(dstW) * dstH * 4, 0);
    uint8_t* dst[4] = {out->pixels.data(), nullptr, nullptr, nullptr};
    int linesizes[4] = {dstW * 4, 0, 0, 0};
    sws_scale(swsV, frame->data, frame->linesize, 0, srcH, dst, linesizes);
    return true;
  }
};

PlaybackSession* PlaybackSession::create(const std::string& path,
                                         int videoWidth) {
  auto* session = new PlaybackSession();
  auto* impl = new Impl();
  impl->path = path;
  impl->videoWidth = videoWidth > 0 ? videoWidth : 960;
  const Error err = impl->openInput();
  if (err != Error::None) {
    delete impl;
    delete session;
    setLastError("playback open failed: " + path);
    return nullptr;
  }
  if (impl->aIdx >= 0) {
    AVChannelLayout stereo;
    av_channel_layout_default(&stereo, kChannels);
    swr_alloc_set_opts2(&impl->swrA, &stereo, AV_SAMPLE_FMT_FLT, kSampleRate,
                        &impl->aDec->ch_layout,
                        static_cast<AVSampleFormat>(impl->aDec->sample_fmt),
                        impl->aDec->sample_rate, 0, nullptr);
    av_channel_layout_uninit(&stereo);
    if (!impl->swrA || swr_init(impl->swrA) < 0) {
      delete impl;
      delete session;
      setLastError("audio resampler init failed");
      return nullptr;
    }
  }
  session->impl_ = impl;
  return session;
}

Error PlaybackSession::start() {
  auto* p = impl_;

  if (p->aDec) {
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = kChannels;
    cfg.sampleRate = kSampleRate;
    cfg.periodSizeInFrames = 480;
    cfg.dataCallback = &Impl::audioCallback;
    cfg.pUserData = p;
    if (ma_device_init(nullptr, &cfg, &p->device) == MA_SUCCESS) {
      if (ma_device_start(&p->device) == MA_SUCCESS) {
        p->deviceRunning = true;
      } else {
        ma_device_uninit(&p->device);
      }
    } else {
      CC_LOG_WARN("no audio device available, using wall clock");
    }
  }
  {
    std::lock_guard<std::mutex> lock(p->clockMutex);
    p->audioClockValid = p->deviceRunning;
    p->basePosition = 0;
    p->framesPlayed = 0;
    p->wallAccumulated = 0;
    p->wallAnchor = std::chrono::steady_clock::now();
  }

  p->paused.store(false);
  p->exiting.store(false);
  p->demuxThread = std::thread([p] { p->demuxMain(); });
  p->audioThread = std::thread([p] { p->audioMain(); });
  if (p->vDec) {
    p->videoThread = std::thread([p] { p->videoMain(); });
  }
  return Error::None;
}

void PlaybackSession::pause() {
  auto* p = impl_;
  if (p->paused.exchange(true)) return;
  if (p->deviceRunning) ma_device_stop(&p->device);
  std::lock_guard<std::mutex> lock(p->clockMutex);
  if (!p->audioClockValid) {
    p->wallAccumulated += std::chrono::duration<double>(
                              std::chrono::steady_clock::now() - p->wallAnchor)
                              .count();
  }
}

void PlaybackSession::resume() {
  auto* p = impl_;
  if (!p->paused.exchange(false)) return;
  std::lock_guard<std::mutex> lock(p->clockMutex);
  p->wallAnchor = std::chrono::steady_clock::now();
  if (p->deviceRunning) ma_device_start(&p->device);
}

bool PlaybackSession::isPlaying() const {
  auto* p = impl_;
  return !p->paused.load() && !p->exiting.load();
}

Error PlaybackSession::seek(double seconds) {
  auto* p = impl_;
  seconds = std::max(0.0, seconds);

  const bool wasPaused = p->paused.exchange(true);
  // Order matters: post the position first, then bump the generation. The
  // worker threads react to the generation change by flushing their own codec,
  // and demuxMain performs the actual file seek.
  p->seekRequest.store(seconds);
  p->generation.fetch_add(1);
  p->ring.clear();

  {
    std::lock_guard<std::mutex> lock(p->frameMutex);
    p->latestFrame.reset();
  }
  {
    std::lock_guard<std::mutex> lock(p->clockMutex);
    p->basePosition = seconds;
    p->framesPlayed = 0;
    p->wallAccumulated = 0;
    p->wallAnchor = std::chrono::steady_clock::now();
  }
  p->videoEof.store(false);
  p->audioEof.store(false);
  if (!wasPaused) {
    p->paused.store(false);
  }
  if (p->deviceRunning) ma_device_start(&p->device);
  return Error::None;
}

double PlaybackSession::positionSeconds() const {
  return impl_->clockSeconds();
}

double PlaybackSession::durationSeconds() const { return impl_->durationSec; }

double PlaybackSession::fps() const {
  return impl_->vFps.num > 0 ? av_q2d(impl_->vFps) : 30.0;
}

bool PlaybackSession::reachedEnd() const {
  auto* p = impl_;
  if (p->durationSec <= 0) return false;
  return positionSeconds() >= p->durationSec - 0.05 &&
         (p->vDec == nullptr || p->videoEof.load());
}

const uint8_t* PlaybackSession::lockFrame(int* outW, int* outH) {
  auto* p = impl_;
  p->frameMutex.lock();
  if (!p->latestFrame) {
    p->frameMutex.unlock();
    if (outW) *outW = 0;
    if (outH) *outH = 0;
    return nullptr;
  }
  if (outW) *outW = p->latestFrame->w;
  if (outH) *outH = p->latestFrame->h;
  return p->latestFrame->pixels.data();
}

void PlaybackSession::unlockFrame() { impl_->frameMutex.unlock(); }

PlaybackSession::~PlaybackSession() {
  auto* p = impl_;
  if (!p) return;
  p->exiting.store(true);
  p->paused.store(false);
  if (p->deviceRunning) ma_device_stop(&p->device);
  if (p->videoThread.joinable()) p->videoThread.join();
  if (p->audioThread.joinable()) p->audioThread.join();
  if (p->demuxThread.joinable()) p->demuxThread.join();
  if (p->deviceRunning) ma_device_uninit(&p->device);
  if (p->swsV) sws_freeContext(p->swsV);
  if (p->swrA) swr_free(&p->swrA);
  if (p->vDec) avcodec_free_context(&p->vDec);
  if (p->aDec) avcodec_free_context(&p->aDec);
  if (p->format) avformat_close_input(&p->format);
  delete p;
}

}  // namespace cc
