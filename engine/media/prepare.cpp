#include "media/prepare.h"

#include <algorithm>
#include <array>
#include <cstdio>
#include <iomanip>
#include <limits>
#include <memory>
#include <sstream>
#include <vector>

#include <nlohmann/json.hpp>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/mem.h>
#include <libavutil/sha.h>
#include <libswresample/swresample.h>
}

#include "core/result.h"

namespace cc {

Error hashFileSha256(const std::string& path, std::string* outHash) {
  if (path.empty() || !outHash) return Error::InvalidArgument;
  FILE* file = std::fopen(path.c_str(), "rb");
  if (!file) {
    setLastError("cannot open file for hashing: " + path);
    return Error::IoError;
  }
  AVSHA* sha = av_sha_alloc();
  if (!sha || av_sha_init(sha, 256) < 0) {
    std::fclose(file);
    av_free(sha);
    setLastError("cannot initialize SHA-256");
    return Error::InternalError;
  }
  std::array<uint8_t, 1 << 16> buffer{};
  while (const size_t count = std::fread(buffer.data(), 1, buffer.size(), file)) {
    av_sha_update(sha, buffer.data(), count);
  }
  const bool readError = std::ferror(file) != 0;
  std::fclose(file);
  if (readError) {
    av_free(sha);
    setLastError("error while hashing file: " + path);
    return Error::IoError;
  }
  std::array<uint8_t, 32> digest{};
  av_sha_final(sha, digest.data());
  av_free(sha);
  std::ostringstream text;
  text << "sha256:" << std::hex << std::setfill('0');
  for (uint8_t byte : digest) text << std::setw(2) << static_cast<unsigned>(byte);
  *outHash = text.str();
  return Error::None;
}

Error extractWaveform(const std::string& path, int peaksPerSecond,
                      std::string* outJson) {
  if (path.empty() || !outJson || peaksPerSecond < 1 || peaksPerSecond > 1000) {
    return Error::InvalidArgument;
  }
  AVFormatContext* format = nullptr;
  AVCodecContext* decoder = nullptr;
  SwrContext* resampler = nullptr;
  AVPacket* packet = nullptr;
  AVFrame* frame = nullptr;
  auto cleanup = [&]() {
    av_packet_free(&packet);
    av_frame_free(&frame);
    swr_free(&resampler);
    avcodec_free_context(&decoder);
    avformat_close_input(&format);
  };
  if (avformat_open_input(&format, path.c_str(), nullptr, nullptr) < 0 ||
      avformat_find_stream_info(format, nullptr) < 0) {
    cleanup();
    setLastError("cannot open media for waveform: " + path);
    return Error::MediaOpenFailed;
  }
  const AVCodec* codec = nullptr;
  const int streamIndex = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1,
                                               &codec, 0);
  if (streamIndex < 0 || !codec) {
    cleanup();
    setLastError("media has no audio stream");
    return Error::MediaNoStream;
  }
  decoder = avcodec_alloc_context3(codec);
  avcodec_parameters_to_context(decoder, format->streams[streamIndex]->codecpar);
  if (avcodec_open2(decoder, codec, nullptr) < 0) {
    cleanup();
    setLastError("audio decoder open failed");
    return Error::MediaDecodeFailed;
  }
  AVChannelLayout outputLayout;
  av_channel_layout_copy(&outputLayout, &decoder->ch_layout);
  if (outputLayout.nb_channels <= 0) av_channel_layout_default(&outputLayout, 2);
  const int channels = outputLayout.nb_channels;
  const int sampleRate = decoder->sample_rate > 0 ? decoder->sample_rate : 48000;
  if (swr_alloc_set_opts2(&resampler, &outputLayout, AV_SAMPLE_FMT_FLT, sampleRate,
                          &decoder->ch_layout,
                          static_cast<AVSampleFormat>(decoder->sample_fmt),
                          sampleRate, 0, nullptr) < 0 ||
      !resampler || swr_init(resampler) < 0) {
    av_channel_layout_uninit(&outputLayout);
    cleanup();
    setLastError("waveform resampler init failed");
    return Error::InternalError;
  }
  av_channel_layout_uninit(&outputLayout);

  const int bucketFrames = std::max(1, sampleRate / peaksPerSecond);
  int framesInBucket = 0;
  std::vector<float> minima(channels, 1.0f);
  std::vector<float> maxima(channels, -1.0f);
  nlohmann::json peaks = nlohmann::json::array();
  auto finishBucket = [&]() {
    if (!framesInBucket) return;
    nlohmann::json bucket = nlohmann::json::array();
    for (int c = 0; c < channels; ++c)
      bucket.push_back({std::clamp(minima[c], -1.0f, 1.0f),
                        std::clamp(maxima[c], -1.0f, 1.0f)});
    peaks.push_back(std::move(bucket));
    framesInBucket = 0;
    std::fill(minima.begin(), minima.end(), 1.0f);
    std::fill(maxima.begin(), maxima.end(), -1.0f);
  };
  auto consumeFrame = [&](AVFrame* decoded) {
    const int capacity = swr_get_out_samples(resampler, decoded->nb_samples);
    std::vector<float> samples(static_cast<size_t>(capacity) * channels);
    uint8_t* output[] = {reinterpret_cast<uint8_t*>(samples.data())};
    const int converted = swr_convert(resampler, output, capacity,
                                      const_cast<const uint8_t**>(decoded->extended_data),
                                      decoded->nb_samples);
    for (int i = 0; i < converted; ++i) {
      for (int c = 0; c < channels; ++c) {
        const float value = samples[static_cast<size_t>(i) * channels + c];
        minima[c] = std::min(minima[c], value);
        maxima[c] = std::max(maxima[c], value);
      }
      if (++framesInBucket == bucketFrames) finishBucket();
    }
  };

  packet = av_packet_alloc();
  frame = av_frame_alloc();
  while (av_read_frame(format, packet) >= 0) {
    if (packet->stream_index == streamIndex && avcodec_send_packet(decoder, packet) >= 0) {
      while (avcodec_receive_frame(decoder, frame) == 0) {
        consumeFrame(frame);
        av_frame_unref(frame);
      }
    }
    av_packet_unref(packet);
  }
  avcodec_send_packet(decoder, nullptr);
  while (avcodec_receive_frame(decoder, frame) == 0) {
    consumeFrame(frame);
    av_frame_unref(frame);
  }
  finishBucket();
  *outJson = nlohmann::json{{"sampleRate", sampleRate},
                            {"channels", channels},
                            {"peaksPerSecond", peaksPerSecond},
                            {"peaks", std::move(peaks)}}.dump();
  cleanup();
  return Error::None;
}

}  // namespace cc
