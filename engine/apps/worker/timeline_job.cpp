// Timeline job implementation. See timeline_job.hpp.

#include "timeline_job.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#include "audio/mixer.h"
#include "core/time.h"
#include "media/frame.h"
#include "model/project.h"
#include "render/renderer.h"

using json = nlohmann::json;

namespace cc {
namespace {

void emit(const json& line) {
  std::cout << line.dump() << "\n";
  std::cout.flush();
}

struct VideoSettings {
  std::string codec = "h264";
  int crf = 18;
  std::string preset = "medium";
  bool enabled = true;
  int maxWidth = 0;
  int maxHeight = 0;
};

struct AudioSettings {
  std::string codec = "aac";
  int bitrate = 320000;
  bool enabled = true;
  // EXP-7: when set, the mix is normalized to this integrated loudness with
  // the true peak kept under the ceiling.
  std::optional<double> loudnessTargetLufs;
  double truePeakCeilingDb = -1.5;
};

void fitEven(int* w, int* h) {
  *w -= *w % 2;
  *h -= *h % 2;
  if (*w < 2) *w = 2;
  if (*h < 2) *h = 2;
}

// ---------------------------------------------------------------------------
// Audio timeline mixer
// ---------------------------------------------------------------------------

const double kMixRate = 48000.0;

struct AudioClipSpan {
  const json* clip = nullptr;
  std::string path;
  RationalTime start{};   // sequence time
  RationalTime duration{};
  double sourceInSec = 0.0;
  double speed = 1.0;
  double volume = 1.0;
  double pan = 0.0;
  double fadeInSec = 0.0;
  double fadeOutSec = 0.0;
};

double fadeGain(double posSec, double clipDur, double inSec, double outSec) {
  double g = 1.0;
  if (inSec > 0.0 && posSec < inSec) g *= posSec / inSec;  // linear (AUD v1)
  if (outSec > 0.0 && posSec > clipDur - outSec) {
    const double d = std::max(0.0, clipDur - posSec);
    g *= d / outSec;
  }
  return std::clamp(g, 0.0, 1.0);
}

// Decodes [path] fully to stereo f32 at kMixRate and appends into [dst].
// Returns false on decode failure (span treated as silence).
bool decodeToStereo(const std::string& path, double sourceInSec, double seconds,
                    std::vector<float>* dst) {
  AVFormatContext* fmt = nullptr;
  if (avformat_open_input(&fmt, path.c_str(), nullptr, nullptr) < 0) return false;
  if (avformat_find_stream_info(fmt, nullptr) < 0) {
    avformat_close_input(&fmt);
    return false;
  }
  const int aIdx = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
  if (aIdx < 0) {
    avformat_close_input(&fmt);
    return true;  // no audio stream: silence is correct
  }
  AVCodecContext* dec = avcodec_alloc_context3(
      avcodec_find_decoder(fmt->streams[aIdx]->codecpar->codec_id));
  avcodec_parameters_to_context(dec, fmt->streams[aIdx]->codecpar);
  if (avcodec_open2(dec, dec->codec, nullptr) < 0) {
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    return false;
  }

  SwrContext* swr = nullptr;
  AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
  swr_alloc_set_opts2(&swr, &stereo, AV_SAMPLE_FMT_FLT, static_cast<int>(kMixRate),
                      &dec->ch_layout, dec->sample_fmt, dec->sample_rate, 0, nullptr);
  if (!swr || swr_init(swr) < 0) {
    swr_free(&swr);
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    return false;
  }

  // Seek near the in-point.
  const AVRational tb = fmt->streams[aIdx]->time_base;
  const int64_t seekTs = static_cast<int64_t>(sourceInSec / av_q2d(tb));
  av_seek_frame(fmt, aIdx, seekTs >= 0 ? seekTs : 0, AVSEEK_FLAG_BACKWARD);
  avcodec_flush_buffers(dec);

  const size_t wantSamples = static_cast<size_t>(std::llround(seconds * kMixRate));
  size_t produced = 0;
  // Small pre-roll so resampler warm-up doesn't shift the waveform.
  const double preroll = 0.05;
  size_t skip = static_cast<size_t>(
      std::llround(sourceInSec > 0 ? preroll * kMixRate : 0));

  AVPacket* pkt = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  bool eof = false;
  while (produced < wantSamples && !eof) {
    if (av_read_frame(fmt, pkt) < 0) eof = true;
    if (!eof && pkt->stream_index != aIdx) {
      av_packet_unref(pkt);
      continue;
    }
    if (avcodec_send_packet(dec, eof ? nullptr : pkt) < 0) {
      av_packet_unref(pkt);
      break;
    }
    while (produced < wantSamples) {
      if (avcodec_receive_frame(dec, frame) < 0) break;
      const int64_t got = swr_get_out_samples(swr, frame->nb_samples);
      if (got <= 0) continue;
      std::vector<uint8_t> buf(static_cast<size_t>(got) * 2 *
                               sizeof(float));
      uint8_t* outPtr[1] = {buf.data()};
      const int n = swr_convert(swr, outPtr, got,
                                const_cast<const uint8_t**>(frame->extended_data),
                                frame->nb_samples);
      if (n <= 0) continue;
      const float* samples = reinterpret_cast<const float*>(buf.data());
      for (int i = 0; i < n; ++i) {
        if (skip > 0) {
          --skip;
          continue;
        }
        dst->push_back(samples[i * 2]);
        dst->push_back(samples[i * 2 + 1]);
        ++produced;
        if (produced >= wantSamples) break;
      }
    }
    av_packet_unref(pkt);
  }

  av_frame_free(&frame);
  av_packet_free(&pkt);
  swr_free(&swr);
  avcodec_free_context(&dec);
  avformat_close_input(&fmt);
  return true;
}

}  // namespace

json parseJobFile(const std::string& path) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) throw std::runtime_error("cannot open job file: " + path);
  std::string contents;
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) contents.append(buf, n);
  fclose(f);
  return json::parse(contents);
}

int runTimelineJob(const json& spec) {
  const auto clockStart = std::chrono::steady_clock::now();

  const json document = spec.at("document");
  std::map<std::string, std::string> media;
  if (spec.contains("media") && spec["media"].is_object()) {
    for (auto it = spec["media"].begin(); it != spec["media"].end(); ++it) {
      media[it.key()] = it.value().get<std::string>();
    }
  }
  const std::string output = spec.at("output").get<std::string>();

  VideoSettings vs;
  if (spec.contains("video")) {
    const auto& v = spec["video"];
    if (v.is_null()) vs.enabled = false;
    if (v.contains("codec")) vs.codec = v["codec"].get<std::string>();
    if (v.contains("crf")) vs.crf = v["crf"].get<int>();
    if (v.contains("preset")) vs.preset = v["preset"].get<std::string>();
    if (v.contains("maxWidth")) vs.maxWidth = v["maxWidth"].get<int>();
    if (v.contains("maxHeight")) vs.maxHeight = v["maxHeight"].get<int>();
  }
  std::optional<AudioSettings> as{AudioSettings{}};
  if (spec.contains("audio")) {
    const auto& a = spec["audio"];
    if (a.is_null()) as.reset();
    else {
      if (a.contains("codec")) as->codec = a["codec"].get<std::string>();
      if (a.contains("bitrate")) as->bitrate = a["bitrate"].get<int>();
      if (a.contains("loudnessLufs") && a["loudnessLufs"].is_number()) {
        as->loudnessTargetLufs = a["loudnessLufs"].get<double>();
      }
      if (a.contains("truePeakDb") && a["truePeakDb"].is_number()) {
        as->truePeakCeilingDb = a["truePeakDb"].get<double>();
      }
    }
  }
  const bool faststart = spec.value("faststart", true);

  ProjectSnapshot snapshot;
  const Error loadErr =
      snapshot.load(document.dump(), /*repairInvalid=*/false);
  if (loadErr != Error::None) {
    throw std::runtime_error("project failed engine validation: " +
                             std::string(lastError()));
  }

  // Sequence geometry.
  int width = document["settings"].value("width", 1920);
  int height = document["settings"].value("height", 1080);
  fitEven(&width, &height);
  const auto fpsRt = parseJsonTime(document["settings"]["fps"]);
  if (!fpsRt || fpsRt->num <= 0) throw std::runtime_error("invalid fps");
  AVRational fps{static_cast<int>(fpsRt->num), fpsRt->den};
  const RationalTime seqDuration = snapshot.duration();

  emit(json{{"type", "started"},
            {"totalFrames",
             static_cast<int64_t>(seqDuration.toSeconds() * av_q2d(fps))},
            {"durationSeconds", seqDuration.toSeconds()},
            {"width", width},
            {"height", height}});

  // --- Output context -------------------------------------------------------
  AVFormatContext* outFmt = nullptr;
  if (avformat_alloc_output_context2(&outFmt, nullptr, nullptr, output.c_str()) < 0) {
    throw std::runtime_error("cannot create output context");
  }

  AVCodecContext* vEnc = nullptr;
  AVStream* vOut = nullptr;
  SwsContext* toYuv = nullptr;
  AVFrame* vFrame = nullptr;

  AVCodecContext* aEnc = nullptr;
  AVStream* aOut = nullptr;
  AVAudioFifo* fifo = nullptr;
  AVFrame* aFrame = nullptr;
  int64_t samplesWritten = 0;

  auto cleanup = [&]() {
    if (vEnc) avcodec_free_context(&vEnc);
    if (vFrame) av_frame_free(&vFrame);
    if (toYuv) sws_freeContext(toYuv);
    if (aEnc) avcodec_free_context(&aEnc);
    if (aFrame) av_frame_free(&aFrame);
    if (fifo) av_audio_fifo_free(fifo);
    if (outFmt && !(outFmt->oformat->flags & AVFMT_NOFILE)) avio_closep(&outFmt->pb);
    if (outFmt) avformat_free_context(outFmt);
  };

  try {
    // --- Video encoder ------------------------------------------------------
    if (vs.enabled) {
      const std::string name = vs.codec == "h265" || vs.codec == "hevc" ? "libx265"
                                                                        : "libx264";
      const AVCodec* codec = avcodec_find_encoder_by_name(name.c_str());
      if (!codec) throw std::runtime_error("encoder not found: " + name);
      vEnc = avcodec_alloc_context3(codec);
      vEnc->width = width;
      vEnc->height = height;
      vEnc->pix_fmt = AV_PIX_FMT_YUV420P;
      vEnc->time_base = av_inv_q(fps);
      vEnc->framerate = fps;
      vEnc->gop_size = std::max(12, static_cast<int>(av_q2d(fps) * 2.0));
      vEnc->max_b_frames = 2;
      char crfStr[16];
      snprintf(crfStr, sizeof(crfStr), "%d", vs.crf);
      av_opt_set(vEnc->priv_data, "crf", crfStr, 0);
      av_opt_set(vEnc->priv_data, "preset", vs.preset.c_str(), 0);
      if (outFmt->oformat->flags & AV_CODEC_FLAG_GLOBAL_HEADER)
        vEnc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
      if (avcodec_open2(vEnc, codec, nullptr) < 0)
        throw std::runtime_error("video encoder open failed");

      vOut = avformat_new_stream(outFmt, nullptr);
      avcodec_parameters_from_context(vOut->codecpar, vEnc);
      vOut->time_base = vEnc->time_base;

      vFrame = av_frame_alloc();
      vFrame->format = vEnc->pix_fmt;
      vFrame->width = width;
      vFrame->height = height;
      if (av_frame_get_buffer(vFrame, 32) < 0)
        throw std::runtime_error("video frame buffer alloc failed");

      toYuv = sws_getContext(width, height, AV_PIX_FMT_RGBA, width, height,
                             AV_PIX_FMT_YUV420P, SWS_BILINEAR, nullptr, nullptr,
                             nullptr);
      if (!toYuv) throw std::runtime_error("rgba→yuv scaler init failed");
    }

    // --- Audio: pre-mix the whole sequence ---------------------------------
    // Preview and export share cc::mixTimeline, so the file carries exactly
    // the balance, fades and crossfades the monitor played (arch §1).
    AudioBuffer mix;
    if (as.has_value()) {
      const Error mixErr =
          mixTimeline(document, media, 0.0, seqDuration.toSeconds(),
                      static_cast<int>(kMixRate), masterFromDocument(document),
                      &mix);
      if (mixErr != Error::None) throw std::runtime_error("audio mix failed");

      if (as->loudnessTargetLufs.has_value()) {
        // EXP-7 / AUD-12: measure, then apply one corrective gain — the
        // "two-pass loudnorm" shape without a second encode.
        const double measured = integratedLufs(mix);
        if (measured > -70.0) {
          double gain =
              std::pow(10.0, (*as->loudnessTargetLufs - measured) / 20.0);
          // Respect the true-peak ceiling rather than clipping into it.
          const double tp = truePeakDb(mix);
          if (tp > -120.0) {
            const double headroom =
                std::pow(10.0, (as->truePeakCeilingDb - tp) / 20.0);
            gain = std::min(gain, headroom);
          }
          for (float& sample : mix.samples) {
            sample = static_cast<float>(
                std::clamp(sample * gain, -1.0, 1.0));
          }
        }
      }
    }

    // --- Audio encoder ------------------------------------------------------
    if (as.has_value()) {
      const AVCodec* codec = avcodec_find_encoder_by_name(as->codec.c_str());
      if (!codec) throw std::runtime_error("audio encoder not found: " + as->codec);
      aEnc = avcodec_alloc_context3(codec);
      aEnc->sample_rate = static_cast<int>(kMixRate);
      AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
      av_channel_layout_copy(&aEnc->ch_layout, &stereo);
      aEnc->sample_fmt = codec->sample_fmts ? codec->sample_fmts[0]
                                            : AV_SAMPLE_FMT_FLTP;
      aEnc->bit_rate = as->bitrate;
      if (outFmt->oformat->flags & AV_CODEC_FLAG_GLOBAL_HEADER)
        aEnc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
      if (avcodec_open2(aEnc, codec, nullptr) < 0)
        throw std::runtime_error("audio encoder open failed");
      aOut = avformat_new_stream(outFmt, nullptr);
      avcodec_parameters_from_context(aOut->codecpar, aEnc);
      aOut->time_base = AVRational{1, aEnc->sample_rate};
      fifo = av_audio_fifo_alloc(aEnc->sample_fmt, 2,
                                 aEnc->frame_size > 0 ? aEnc->frame_size * 4 : 4096);
      aFrame = av_frame_alloc();
      aFrame->format = aEnc->sample_fmt;
      aFrame->ch_layout = aEnc->ch_layout;
      aFrame->sample_rate = aEnc->sample_rate;
      aFrame->nb_samples = aEnc->frame_size > 0 ? aEnc->frame_size : 1024;
      if (av_frame_get_buffer(aFrame, 0) < 0)
        throw std::runtime_error("audio frame buffer alloc failed");
    }

    if (!(outFmt->oformat->flags & AVFMT_NOFILE)) {
      if (avio_open(&outFmt->pb, output.c_str(), AVIO_FLAG_WRITE) < 0)
        throw std::runtime_error("cannot open output for writing");
    }
    AVDictionary* opts = nullptr;
    if (faststart) av_dict_set(&opts, "movflags", "+faststart", 0);
    if (avformat_write_header(outFmt, &opts) < 0)
      throw std::runtime_error("write_header failed");
    av_dict_free(&opts);

    // --- Encode helpers -----------------------------------------------------
    auto writePacket = [&](AVPacket* pkt, AVCodecContext* enc, AVStream* stream) {
      av_packet_rescale_ts(pkt, enc->time_base, stream->time_base);
      pkt->stream_index = stream->index;
      if (av_interleaved_write_frame(outFmt, pkt) < 0)
        throw std::runtime_error("mux write failed");
    };

    const int64_t totalFrames =
        static_cast<int64_t>(seqDuration.toSeconds() * av_q2d(fps) + 0.5);
    RgbaSurface canvas;
    int64_t encoded = 0;

    // Feed mixed PCM into fifo and drain full frames (or all when draining).
    auto pushMixToFifo = [&]() {
      if (!as.has_value() || !aEnc) return;
      // The mixer already hands back interleaved stereo float.
      const size_t total = mix.frames();
      const std::vector<float>& inter = mix.samples;
      // Convert interleaved FLT → planar encoder format.
      SwrContext* cvt = nullptr;
      AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
      AVChannelLayout encLayout;
      av_channel_layout_copy(&encLayout, &aEnc->ch_layout);
      swr_alloc_set_opts2(&cvt, &encLayout, aEnc->sample_fmt, aEnc->sample_rate,
                          &stereo, AV_SAMPLE_FMT_FLT, static_cast<int>(kMixRate),
                          0, nullptr);
      if (!cvt || swr_init(cvt) < 0) throw std::runtime_error("mix converter failed");
      const int maxOut = static_cast<int>(total) + 512;
      std::vector<uint8_t> planar(static_cast<size_t>(maxOut) * 2 * sizeof(float));
      uint8_t* planes[2] = {planar.data(),
                            planar.data() + static_cast<size_t>(maxOut) * sizeof(float)};
      const uint8_t* srcPlanes[1] = {
          reinterpret_cast<const uint8_t*>(inter.data())};
      const int converted =
          swr_convert(cvt, planes, maxOut, srcPlanes, static_cast<int>(total));
      swr_free(&cvt);
      if (converted <= 0) return;
      const float* chL = reinterpret_cast<const float*>(planes[0]);
      const float* chR = reinterpret_cast<const float*>(planes[1]);
      if (av_audio_fifo_realloc(fifo, av_audio_fifo_size(fifo) + converted) < 0)
        throw std::runtime_error("fifo realloc failed");
      // Deinterleave into fifo channel pointers.
      std::vector<uint8_t*> writePtrs(2);
      std::vector<float> tmpL(converted), tmpR(converted);
      for (int i = 0; i < converted; ++i) {
        tmpL[i] = chL[i];
        tmpR[i] = chR[i];
      }
      writePtrs[0] = reinterpret_cast<uint8_t*>(tmpL.data());
      writePtrs[1] = reinterpret_cast<uint8_t*>(tmpR.data());
      if (av_audio_fifo_write(fifo, reinterpret_cast<void**>(writePtrs.data()),
                              converted) < converted)
        throw std::runtime_error("fifo write failed");
    };

    auto encodeQueuedAudio = [&](bool drain) {
      AVPacket* pkt = av_packet_alloc();
      while (drain || av_audio_fifo_size(fifo) >= aEnc->frame_size) {
        const int read = av_audio_fifo_read(fifo,
                                            reinterpret_cast<void**>(aFrame->data),
                                            aEnc->frame_size);
        if (read <= 0) break;
        aFrame->nb_samples = read;
        aFrame->pts = samplesWritten;
        samplesWritten += read;
        if (avcodec_send_frame(aEnc, aFrame) < 0) {
          av_packet_free(&pkt);
          throw std::runtime_error("audio send_frame failed");
        }
        while (avcodec_receive_packet(aEnc, pkt) == 0) {
          writePacket(pkt, aEnc, aOut);
          av_packet_unref(pkt);
        }
        if (av_audio_fifo_size(fifo) < aEnc->frame_size && !drain) break;
      }
      av_packet_free(&pkt);
    };

    if (as.has_value()) {
      pushMixToFifo();
      encodeQueuedAudio(false);
    }

    // --- Frame loop ---------------------------------------------------------
    for (int64_t f = 0; f < totalFrames; ++f) {
      const RationalTime t = RationalTime::fromSeconds(
          static_cast<double>(f) / av_q2d(fps));
      const Error err = renderFrame(document, t.normalized(), width, height, media,
                                    &canvas);
      if (err != Error::None) throw std::runtime_error("renderFrame failed");

      if (vEnc) {
        if (av_frame_make_writable(vFrame) < 0)
          throw std::runtime_error("frame not writable");
        const uint8_t* srcData[4] = {canvas.rgba.data(), nullptr, nullptr, nullptr};
        const int srcStride[4] = {canvas.width * 4, 0, 0, 0};
        sws_scale(toYuv, srcData, srcStride, 0, height, vFrame->data,
                  vFrame->linesize);
        vFrame->pts = f;
        if (avcodec_send_frame(vEnc, vFrame) < 0)
          throw std::runtime_error("send_frame failed");
        AVPacket* pkt = av_packet_alloc();
        while (avcodec_receive_packet(vEnc, pkt) == 0) {
          writePacket(pkt, vEnc, vOut);
          av_packet_unref(pkt);
        }
        av_packet_free(&pkt);
      }
      ++encoded;
      if (encoded % 30 == 0) {
        emit(json{{"type", "progress"},
                  {"frame", encoded},
                  {"totalFrames", totalFrames},
                  {"percent",
                   totalFrames > 0
                       ? std::min(100.0, 100.0 * static_cast<double>(encoded) /
                                             static_cast<double>(totalFrames))
                       : 100.0}});
      }
    }

    if (vEnc) {
      if (avcodec_send_frame(vEnc, nullptr) < 0)
        throw std::runtime_error("flush send failed");
      AVPacket* pkt = av_packet_alloc();
      while (avcodec_receive_packet(vEnc, pkt) == 0) {
        writePacket(pkt, vEnc, vOut);
        av_packet_unref(pkt);
      }
      av_packet_free(&pkt);
    }
    if (aEnc) {
      encodeQueuedAudio(true);
      if (avcodec_send_frame(aEnc, nullptr) < 0)
        throw std::runtime_error("audio flush failed");
      AVPacket* pkt = av_packet_alloc();
      while (avcodec_receive_packet(aEnc, pkt) == 0) {
        writePacket(pkt, aEnc, aOut);
        av_packet_unref(pkt);
      }
      av_packet_free(&pkt);
    }

    av_write_trailer(outFmt);
    lastJobBytesValue = 0;
    FILE* fh = fopen(output.c_str(), "rb");
    if (fh) {
      fseek(fh, 0, SEEK_END);
      lastJobBytesValue = ftell(fh);
      fclose(fh);
    }
    lastJobSecondsValue =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - clockStart)
            .count();
    cleanup();
    return 0;
  } catch (...) {
    cleanup();
    throw;
  }
}

}  // namespace cc
