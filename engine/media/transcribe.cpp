#include "media/transcribe.h"

#include <algorithm>
#include <cstring>
#include <vector>

#include <nlohmann/json.hpp>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
}

#ifdef CC_HAS_WHISPER
#include <whisper.h>
#endif

#include "core/result.h"

namespace cc {
namespace {

// Whisper models are trained on 16 kHz mono; anything else has to be resampled
// to that before it is fed in, so this is fixed rather than configurable.
constexpr int kWhisperSampleRate = 16000;

/// Decodes the whole audio stream of [path] to 16 kHz mono float.
///
/// The full buffer is held in memory because whisper wants a contiguous span:
/// at 64 KB per second, an hour of audio is roughly 230 MB, which is the real
/// ceiling on how long a clip can be transcribed in one pass.
Error decodeMonoPcm(const std::string& path, std::vector<float>* out,
                    double* outDurationSeconds) {
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
    setLastError("cannot open media for transcription: " + path);
    return Error::MediaOpenFailed;
  }

  const AVCodec* codec = nullptr;
  const int streamIndex =
      av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
  if (streamIndex < 0 || !codec) {
    cleanup();
    setLastError("media has no audio stream to transcribe");
    return Error::MediaNoStream;
  }

  decoder = avcodec_alloc_context3(codec);
  avcodec_parameters_to_context(decoder, format->streams[streamIndex]->codecpar);
  if (avcodec_open2(decoder, codec, nullptr) < 0) {
    cleanup();
    setLastError("audio decoder open failed");
    return Error::MediaDecodeFailed;
  }

  AVChannelLayout monoLayout;
  av_channel_layout_default(&monoLayout, 1);
  if (swr_alloc_set_opts2(&resampler, &monoLayout, AV_SAMPLE_FMT_FLT,
                          kWhisperSampleRate, &decoder->ch_layout,
                          static_cast<AVSampleFormat>(decoder->sample_fmt),
                          decoder->sample_rate > 0 ? decoder->sample_rate
                                                   : kWhisperSampleRate,
                          0, nullptr) < 0 ||
      !resampler || swr_init(resampler) < 0) {
    av_channel_layout_uninit(&monoLayout);
    cleanup();
    setLastError("transcription resampler init failed");
    return Error::InternalError;
  }
  av_channel_layout_uninit(&monoLayout);

  auto consume = [&](AVFrame* decoded) {
    const int capacity = swr_get_out_samples(resampler, decoded->nb_samples);
    if (capacity <= 0) return;
    const size_t offset = out->size();
    out->resize(offset + static_cast<size_t>(capacity));
    uint8_t* output[] = {reinterpret_cast<uint8_t*>(out->data() + offset)};
    const int converted =
        swr_convert(resampler, output, capacity,
                    const_cast<const uint8_t**>(decoded->extended_data),
                    decoded->nb_samples);
    out->resize(offset + static_cast<size_t>(std::max(0, converted)));
  };

  packet = av_packet_alloc();
  frame = av_frame_alloc();
  while (av_read_frame(format, packet) >= 0) {
    if (packet->stream_index == streamIndex &&
        avcodec_send_packet(decoder, packet) >= 0) {
      while (avcodec_receive_frame(decoder, frame) == 0) {
        consume(frame);
        av_frame_unref(frame);
      }
    }
    av_packet_unref(packet);
  }
  avcodec_send_packet(decoder, nullptr);
  while (avcodec_receive_frame(decoder, frame) == 0) {
    consume(frame);
    av_frame_unref(frame);
  }

  if (outDurationSeconds) {
    *outDurationSeconds =
        static_cast<double>(out->size()) / kWhisperSampleRate;
  }
  cleanup();
  return Error::None;
}

std::string trim(const std::string& text) {
  const auto begin = text.find_first_not_of(" \t\r\n");
  if (begin == std::string::npos) return {};
  const auto end = text.find_last_not_of(" \t\r\n");
  return text.substr(begin, end - begin + 1);
}

}  // namespace

bool transcriptionAvailable() {
#ifdef CC_HAS_WHISPER
  return true;
#else
  return false;
#endif
}

Error transcribe(const std::string& mediaPath, const std::string& modelPath,
                 const std::string& language, int threads,
                 std::string* outJson, const TranscribeProgress& onProgress) {
  if (mediaPath.empty() || !outJson) return Error::InvalidArgument;

#ifndef CC_HAS_WHISPER
  (void)modelPath;
  (void)language;
  (void)threads;
  (void)onProgress;
  setLastError(
      "this build of CrazyCut has no speech-to-text support "
      "(configure with -DCC_WITH_WHISPER=ON)");
  return Error::InternalError;
#else
  if (modelPath.empty()) {
    setLastError("no speech model path given");
    return Error::InvalidArgument;
  }

  std::vector<float> pcm;
  double durationSeconds = 0;
  // Decoding is a meaningful slice of the wall clock on a long clip, and it
  // produces no segments, so it gets its own slice of the progress bar rather
  // than looking like a stall.
  if (onProgress) onProgress(0.0);
  const Error decodeError = decodeMonoPcm(mediaPath, &pcm, &durationSeconds);
  if (decodeError != Error::None) return decodeError;
  if (pcm.empty()) {
    setLastError("no audio samples to transcribe");
    return Error::MediaNoStream;
  }
  if (onProgress && !onProgress(0.05)) return Error::Cancelled;

  whisper_context_params contextParams = whisper_context_default_params();
  whisper_context* ctx =
      whisper_init_from_file_with_params(modelPath.c_str(), contextParams);
  if (!ctx) {
    setLastError("could not load the speech model at " + modelPath);
    return Error::IoError;
  }

  whisper_full_params params =
      whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  params.print_progress = false;
  params.print_realtime = false;
  params.print_timestamps = false;
  params.print_special = false;
  params.translate = false;
  params.single_segment = false;
  params.n_threads = threads > 0 ? threads : 4;
  // "auto" already means detect-then-transcribe. `detect_language` is a
  // different thing: it makes whisper_full detect the language and return
  // immediately, producing no segments at all.
  params.language = language.empty() ? "auto" : language.c_str();
  params.detect_language = false;

  // Whisper reports 0..100 over the recognition pass; the decode above already
  // claimed the first 5%.
  struct ProgressState {
    const TranscribeProgress* callback;
    bool cancelled;
  } state{&onProgress, false};

  params.progress_callback_user_data = &state;
  params.progress_callback = [](struct whisper_context*, struct whisper_state*,
                                int progress, void* userData) {
    auto* s = static_cast<ProgressState*>(userData);
    if (!s || !*s->callback) return;
    const double fraction = 0.05 + 0.95 * (progress / 100.0);
    if (!(*s->callback)(std::min(fraction, 1.0))) s->cancelled = true;
  };

  // Cancellation is cooperative and checked between whisper's own work units,
  // matching the export worker's contract (arch §8).
  params.encoder_begin_callback_user_data = &state;
  params.encoder_begin_callback = [](struct whisper_context*,
                                     struct whisper_state*,
                                     void* userData) -> bool {
    auto* s = static_cast<ProgressState*>(userData);
    return !(s && s->cancelled);
  };

  const int status =
      whisper_full(ctx, params, pcm.data(), static_cast<int>(pcm.size()));
  if (status != 0) {
    whisper_free(ctx);
    if (state.cancelled) return Error::Cancelled;
    setLastError("speech recognition failed");
    return Error::InternalError;
  }
  if (state.cancelled) {
    whisper_free(ctx);
    return Error::Cancelled;
  }

  nlohmann::json segments = nlohmann::json::array();
  const int count = whisper_full_n_segments(ctx);
  for (int i = 0; i < count; ++i) {
    const std::string text = trim(whisper_full_get_segment_text(ctx, i));
    if (text.empty()) continue;
    // whisper reports centiseconds; the rest of CrazyCut speaks seconds.
    const double start = whisper_full_get_segment_t0(ctx, i) / 100.0;
    const double end = whisper_full_get_segment_t1(ctx, i) / 100.0;
    segments.push_back({{"start", start}, {"end", end}, {"text", text}});
  }

  std::string detected = "unknown";
  const int languageId = whisper_full_lang_id(ctx);
  if (languageId >= 0) {
    if (const char* name = whisper_lang_str(languageId)) detected = name;
  }
  whisper_free(ctx);

  *outJson = nlohmann::json{{"version", 1},
                            {"language", detected},
                            {"durationSeconds", durationSeconds},
                            {"segments", std::move(segments)}}
                 .dump();
  if (onProgress) onProgress(1.0);
  return Error::None;
#endif
}

}  // namespace cc
