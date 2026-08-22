#include "audio/decode.h"

#include <algorithm>
#include <cmath>
#include <list>
#include <memory>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
}

#include "core/log.h"

namespace cc {
namespace {

constexpr size_t kMaxCachedAudioDecoders = 4;

struct AudioSession {
  std::string path;
  AVFormatContext* format = nullptr;
  AVCodecContext* codec = nullptr;
  SwrContext* swr = nullptr;
  int streamIndex = -1;
  AVStream* stream = nullptr;
  int swrRate = 0;
  bool noAudio = false;

  // Position of the next sample this session would produce, in source
  // seconds. Lets sequential reads continue without a seek.
  double cursorSec = -1.0;

  ~AudioSession() {
    if (swr) swr_free(&swr);
    if (codec) avcodec_free_context(&codec);
    if (format) avformat_close_input(&format);
  }
};

std::list<std::unique_ptr<AudioSession>>& audioCache() {
  thread_local std::list<std::unique_ptr<AudioSession>> cache;
  return cache;
}

Error openAudio(const std::string& path, AudioSession* s) {
  if (avformat_open_input(&s->format, path.c_str(), nullptr, nullptr) < 0) {
    setLastError("cannot open media: " + path);
    return Error::MediaOpenFailed;
  }
  if (avformat_find_stream_info(s->format, nullptr) < 0) {
    setLastError("find_stream_info failed");
    return Error::MediaOpenFailed;
  }
  const AVCodec* decoder = nullptr;
  s->streamIndex =
      av_find_best_stream(s->format, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0);
  if (s->streamIndex < 0 || !decoder) {
    s->noAudio = true;  // silent asset: a valid state, not an error
    return Error::None;
  }
  s->stream = s->format->streams[s->streamIndex];
  s->codec = avcodec_alloc_context3(decoder);
  avcodec_parameters_to_context(s->codec, s->stream->codecpar);
  if (avcodec_open2(s->codec, decoder, nullptr) < 0) {
    setLastError("audio decoder open failed");
    return Error::MediaDecodeFailed;
  }
  return Error::None;
}

Error acquireAudio(const std::string& path, AudioSession** out) {
  auto& cache = audioCache();
  for (auto it = cache.begin(); it != cache.end(); ++it) {
    if ((*it)->path == path) {
      cache.splice(cache.begin(), cache, it);
      *out = cache.front().get();
      return Error::None;
    }
  }
  auto session = std::make_unique<AudioSession>();
  session->path = path;
  const Error err = openAudio(path, session.get());
  if (err != Error::None) return err;
  cache.push_front(std::move(session));
  while (cache.size() > kMaxCachedAudioDecoders) cache.pop_back();
  *out = cache.front().get();
  return Error::None;
}

Error ensureResampler(AudioSession* s, int sampleRate) {
  if (s->swr && s->swrRate == sampleRate) return Error::None;
  if (s->swr) swr_free(&s->swr);
  AVChannelLayout outLayout = AV_CHANNEL_LAYOUT_STEREO;
  AVChannelLayout inLayout = s->codec->ch_layout;
  if (inLayout.nb_channels <= 0) {
    av_channel_layout_default(&inLayout, 2);
  }
  if (swr_alloc_set_opts2(&s->swr, &outLayout, AV_SAMPLE_FMT_FLT, sampleRate,
                          &inLayout, s->codec->sample_fmt,
                          s->codec->sample_rate, 0, nullptr) < 0 ||
      swr_init(s->swr) < 0) {
    if (s->swr) swr_free(&s->swr);
    setLastError("audio resampler init failed");
    return Error::InternalError;
  }
  s->swrRate = sampleRate;
  return Error::None;
}

void seekTo(AudioSession* s, double seconds) {
  const int64_t target =
      static_cast<int64_t>(seconds / av_q2d(s->stream->time_base));
  if (avformat_seek_file(s->format, s->streamIndex, INT64_MIN, target, target,
                         0) < 0) {
    av_seek_frame(s->format, -1, 0, AVSEEK_FLAG_BACKWARD);
  }
  avcodec_flush_buffers(s->codec);
  if (s->swr) {
    swr_free(&s->swr);
    s->swrRate = 0;
  }
  s->cursorSec = -1.0;
}

}  // namespace

Error decodeStereoRange(const std::string& path, double sourceInSec,
                        double seconds, int sampleRate,
                        std::vector<float>* out) {
  if (!out || path.empty() || sampleRate <= 0 || seconds < 0) {
    setLastError("decodeStereoRange: invalid arguments");
    return Error::InvalidArgument;
  }
  sourceInSec = std::max(0.0, sourceInSec);
  const size_t wantFrames =
      static_cast<size_t>(std::ceil(seconds * sampleRate));
  out->assign(wantFrames * 2, 0.f);
  if (wantFrames == 0) return Error::None;

  AudioSession* s = nullptr;
  const Error err = acquireAudio(path, &s);
  if (err != Error::None) return err;
  if (s->noAudio) return Error::None;  // silence

  const Error re = ensureResampler(s, sampleRate);
  if (re != Error::None) return re;

  // Continue where the last read stopped when the caller is walking forward
  // (playback, export); otherwise reposition.
  const double tolerance = 1.0 / sampleRate * 4;
  if (s->cursorSec < 0 || sourceInSec < s->cursorSec - tolerance ||
      sourceInSec > s->cursorSec + 0.5) {
    seekTo(s, std::max(0.0, sourceInSec - 0.05));
    const Error re2 = ensureResampler(s, sampleRate);
    if (re2 != Error::None) return re2;
  }

  AVPacket* pkt = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  std::vector<float> converted;
  size_t written = 0;      // frames written into out
  double writeCursor = sourceInSec;
  bool flushed = false;

  auto emit = [&](const float* data, size_t frames, double frameStartSec) {
    // Place samples by their source timestamp so a seek landing early does not
    // shift the whole range.
    for (size_t i = 0; i < frames; ++i) {
      const double t = frameStartSec + static_cast<double>(i) / sampleRate;
      const long long idx =
          static_cast<long long>(std::llround((t - sourceInSec) * sampleRate));
      if (idx < 0) continue;
      if (static_cast<size_t>(idx) >= wantFrames) break;
      (*out)[static_cast<size_t>(idx) * 2] = data[i * 2];
      (*out)[static_cast<size_t>(idx) * 2 + 1] = data[i * 2 + 1];
      written = std::max(written, static_cast<size_t>(idx) + 1);
    }
    writeCursor = frameStartSec + static_cast<double>(frames) / sampleRate;
  };

  while (written < wantFrames) {
    int ret = avcodec_receive_frame(s->codec, frame);
    if (ret == 0) {
      double ptsSec = writeCursor;
      if (frame->pts != AV_NOPTS_VALUE) {
        ptsSec = static_cast<double>(frame->pts) * av_q2d(s->stream->time_base);
      }
      const int maxOut = swr_get_out_samples(s->swr, frame->nb_samples);
      converted.resize(static_cast<size_t>(std::max(0, maxOut)) * 2);
      uint8_t* dst[1] = {reinterpret_cast<uint8_t*>(converted.data())};
      const int got = swr_convert(s->swr, dst, maxOut,
                                  const_cast<const uint8_t**>(frame->data),
                                  frame->nb_samples);
      if (got > 0) emit(converted.data(), static_cast<size_t>(got), ptsSec);
      av_frame_unref(frame);
      if (writeCursor > sourceInSec + seconds) break;
      continue;
    }
    if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) break;
    if (ret == AVERROR_EOF) break;

    if (av_read_frame(s->format, pkt) < 0) {
      if (!flushed) {
        avcodec_send_packet(s->codec, nullptr);
        flushed = true;
        continue;
      }
      break;
    }
    if (pkt->stream_index == s->streamIndex) {
      if (avcodec_send_packet(s->codec, pkt) < 0) {
        av_packet_unref(pkt);
        break;
      }
    }
    av_packet_unref(pkt);
  }

  av_frame_free(&frame);
  av_packet_free(&pkt);
  s->cursorSec = writeCursor;
  return Error::None;
}

bool hasAudioStream(const std::string& path) {
  AudioSession* s = nullptr;
  if (acquireAudio(path, &s) != Error::None) return false;
  return !s->noAudio;
}

Error scanPeak(const std::string& path, double sourceInSec, double seconds,
               int sampleRate, float* outPeak) {
  if (!outPeak) return Error::InvalidArgument;
  *outPeak = 0.f;
  // Scanned in chunks so a long clip does not need the whole range resident.
  const double chunk = 5.0;
  for (double t = 0; t < seconds; t += chunk) {
    std::vector<float> pcm;
    const Error err = decodeStereoRange(path, sourceInSec + t,
                                        std::min(chunk, seconds - t),
                                        sampleRate, &pcm);
    if (err != Error::None) return err;
    for (const float v : pcm) *outPeak = std::max(*outPeak, std::fabs(v));
  }
  return Error::None;
}

}  // namespace cc
