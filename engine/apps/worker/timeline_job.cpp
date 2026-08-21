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
    std::vector<float> mixL, mixR;
    int mixChannels = 2;
    if (as.has_value()) {
      // Collect audio-bearing clips from every audio track AND the audio half
      // of video clips (linked A/V).
      std::vector<AudioClipSpan> spans;
      for (const auto& track : document.value("tracks", json::array())) {
        if (!track.is_object()) continue;
        const bool audioTrack = track.value("kind", "") == "audio";
        if (track.value("mute", false)) continue;
        for (const auto& c : document.value("clips", json::array())) {
          if (!c.is_object() || c.value("trackId", "") != track.value("id", ""))
            continue;
          if (c.value("mute", false)) continue;
          const std::string mid = c.value("mediaId", "");
          if (mid.empty()) continue;
          const auto mit = media.find(mid);
          if (mit == media.end()) continue;
          // Only decode once per asset: video-track clips only contribute
          // audio when their media actually has an audio stream — decode()
          // answers that cheaply by returning silence for missing streams.
          AudioClipSpan span;
          span.clip = &c;
          span.path = mit->second;
          const auto start = parseJsonTime(c.at("start"));
          const auto dur = parseJsonTime(c.at("duration"));
          if (!start || !dur) continue;
          span.start = *start;
          span.duration = *dur;
          if (c.contains("sourceIn")) {
            if (const auto si = parseJsonTime(c["sourceIn"])) span.sourceInSec = si->toSeconds();
          }
          if (c.contains("speed") && c["speed"].is_object()) {
            span.speed = static_cast<double>(c["speed"].value("num", 1)) /
                         std::max(1, c["speed"].value("den", 1));
          }
          span.volume = std::clamp(c.value("volume", 1.0), 0.0, 4.0);
          span.pan = std::clamp(c.value("pan", 0.0), -1.0, 1.0);
          if (c.contains("fadeIn") && c["fadeIn"].is_object()) {
            if (const auto fd = parseJsonTime(c["fadeIn"]["duration"]))
              span.fadeInSec = fd->toSeconds();
          }
          if (c.contains("fadeOut") && c["fadeOut"].is_object()) {
            if (const auto fd = parseJsonTime(c["fadeOut"]["duration"]))
              span.fadeOutSec = fd->toSeconds();
          }
          (void)audioTrack;
          spans.push_back(std::move(span));
        }
      }

      const size_t totalSamples =
          static_cast<size_t>(std::ceil(seqDuration.toSeconds() * kMixRate));
      mixL.assign(totalSamples, 0.f);
      mixR.assign(totalSamples, 0.f);

      for (auto& span : spans) {
        const double durSec = span.duration.toSeconds();
        const double srcSec = durSec * span.speed;
        std::vector<float> pcm;
        pcm.reserve(static_cast<size_t>(srcSec * kMixRate) * 2 + 4096);
        if (!decodeToStereo(span.path, span.sourceInSec, srcSec, &pcm)) continue;
        const size_t frames = pcm.size() / 2;
        const size_t offset =
            static_cast<size_t>(std::max(0.0, span.start.toSeconds()) * kMixRate);
        const double clipDur = durSec;
        const double panL = span.pan <= 0 ? 1.0 : 1.0 - span.pan;
        const double panR = span.pan >= 0 ? 1.0 : 1.0 + span.pan;
        for (size_t i = 0; i < frames; ++i) {
          const size_t o = offset + i;
          if (o >= totalSamples) break;
          const double pos = static_cast<double>(i) / kMixRate;
          const double gain =
              span.volume * fadeGain(pos, clipDur, span.fadeInSec, span.fadeOutSec);
          mixL[o] += static_cast<float>(pcm[i * 2] * gain * panL);
          mixR[o] += static_cast<float>(pcm[i * 2 + 1] * gain * panR);
        }
      }

      // Constant-power crossfades inside transition overlaps (TRA-8): find
      // overlapping A/B pairs on the same track and re-weight their windows.
      for (const auto& tr : document.value("transitions", json::array())) {
        if (!tr.is_object()) continue;
        const std::string aId = tr.value("aClipId", "");
        const std::string bId = tr.value("bClipId", "");
        const json *aClip = nullptr, *bClip = nullptr;
        for (const auto& c : document.value("clips", json::array())) {
          if (!c.is_object()) continue;
          if (c.value("id", "") == aId) aClip = &c;
          if (c.value("id", "") == bId) bClip = &c;
        }
        if (!aClip || !bClip) continue;
        const auto aS = parseJsonTime(aClip->at("start"));
        const auto aD = parseJsonTime(aClip->at("duration"));
        const auto bS = parseJsonTime(bClip->at("start"));
        const auto bD = parseJsonTime(bClip->at("duration"));
        if (!aS || !aD || !bS || !bD) continue;
        const double ovStart = std::max(aS->toSeconds(), bS->toSeconds());
        const double ovEnd = std::min(aS->toSeconds() + aD->toSeconds(),
                                      bS->toSeconds() + bD->toSeconds());
        if (ovEnd <= ovStart) continue;
        const size_t s0 = static_cast<size_t>(ovStart * kMixRate);
        const size_t s1 = std::min(totalSamples,
                                   static_cast<size_t>(ovEnd * kMixRate));
        // Weight window per clip: A fades out linearly across its own tail,
        // B fades in across its head — constant-power when both present.
        auto weightFor = [&](const json* clip, size_t idx) {
          const auto cs = parseJsonTime(clip->at("start"));
          const auto cd = parseJsonTime(clip->at("duration"));
          const double t = static_cast<double>(idx) / kMixRate;
          const double local = t - cs->toSeconds();
          const double dur = cd->toSeconds();
          double wA = 1.0, wB = 0.0;
          // Fraction through the overlap region measured inside THIS clip:
          double frac = (t - ovStart) / std::max(1e-9, ovEnd - ovStart);
          frac = std::clamp(frac, 0.0, 1.0);
          if (clip == aClip) return 1.0 - frac;
          return frac;
          (void)wA; (void)wB; (void)local; (void)dur;
        };
        for (size_t idx = s0; idx < s1; ++idx) {
          const double wa = weightFor(aClip, idx);
          const double wb = weightFor(bClip, idx);
          const double denom = wa + wb;
          if (denom <= 1e-9) continue;
          const double norm = 1.0 / denom;
          // Re-apply weights relative to each other (both were summed flat):
          // scale each side toward its share of unity power.
          const double pa = wa * norm;
          const double pb = wb * norm;
          const double eqA = pa / std::max(pa, pb);
          const double eqB = pb / std::max(pa, pb);
          mixL[idx] = static_cast<float>(mixL[idx] * (eqA + eqB));
          mixR[idx] = static_cast<float>(mixR[idx] * (eqA + eqB));
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
      // Interleave L/R then convert float → encoder format via swresample-free
      // path: AAC takes FLTP; build planar buffers directly.
      const size_t total = mixL.size();
      std::vector<float> inter(total * 2);
      for (size_t i = 0; i < total; ++i) {
        inter[i * 2] = mixL[i];
        inter[i * 2 + 1] = mixR[i];
      }
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
      const int converted = swr_convert(cvt, planes, maxOut,
                                        const_cast<const uint8_t**>(
                                            reinterpret_cast<const uint8_t**>(&inter)),
                                        static_cast<int>(total));
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
