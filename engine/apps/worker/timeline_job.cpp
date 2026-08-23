// Timeline job implementation. See timeline_job.hpp.

#include "timeline_job.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
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
  bool hardware = false;  // EXP-6, opt-in per job
  // EXP-15: match every visible clip's exposure toward the project median.
  bool matchExposure = false;
};

struct AudioSettings {
  std::string codec = "aac";
  int bitrate = 320000;
  bool enabled = true;
  // EXP-7: when set, the mix is normalized to this integrated loudness with
  // the true peak kept under the ceiling.
  std::optional<double> loudnessTargetLufs;
  double truePeakCeilingDb = -1.5;
  // AUD-16: level each clip toward the median measured loudness before the
  // master bus so no single clip dominates the balance.
  bool levelClips = false;
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
  // EXP-13: encode into a sibling .part and rename on success, so a killed or
  // failed job never leaves something that looks like a finished export.
  const std::string partPath = output + ".part";

  VideoSettings vs;
  if (spec.contains("video")) {
    const auto& v = spec["video"];
    if (v.is_null()) vs.enabled = false;
    if (v.contains("codec")) vs.codec = v["codec"].get<std::string>();
    if (v.contains("crf")) vs.crf = v["crf"].get<int>();
    if (v.contains("preset")) vs.preset = v["preset"].get<std::string>();
    if (v.contains("maxWidth")) vs.maxWidth = v["maxWidth"].get<int>();
    if (v.contains("maxHeight")) vs.maxHeight = v["maxHeight"].get<int>();
    if (v.contains("hardware")) vs.hardware = v["hardware"].get<bool>();
    if (v.contains("matchExposure")) vs.matchExposure = v["matchExposure"].get<bool>();
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
      if (a.contains("levelClips")) as->levelClips = a["levelClips"].get<bool>();
    }
  }
  const bool faststart = spec.value("faststart", true);
  // EXP-1: entire sequence, or the in/out range when the caller sets one.
  const double rangeStartSec = std::max(0.0, spec.value("startSec", 0.0));
  const double rangeEndSec = spec.value("endSec", 0.0);

  ProjectSnapshot snapshot;
  const Error loadErr =
      snapshot.load(document.dump(), /*repairInvalid=*/false);
  if (loadErr != Error::None) {
    throw std::runtime_error("project failed engine validation: " +
                             std::string(lastError()));
  }

  // Sequence geometry. Presets may cap the output size (EXP-3); the frame is
  // still composited at sequence resolution and scaled once on the way to the
  // encoder, so a downscale never changes the composition.
  const int seqWidth = document["settings"].value("width", 1920);
  const int seqHeight = document["settings"].value("height", 1080);
  int width = seqWidth;
  int height = seqHeight;
  if (vs.maxWidth > 0 || vs.maxHeight > 0) {
    const double limitW = vs.maxWidth > 0 ? vs.maxWidth : width;
    const double limitH = vs.maxHeight > 0 ? vs.maxHeight : height;
    const double scale = std::min({1.0, limitW / width, limitH / height});
    width = static_cast<int>(std::lround(width * scale));
    height = static_cast<int>(std::lround(height * scale));
  }
  fitEven(&width, &height);
  int renderWidth = seqWidth;
  int renderHeight = seqHeight;
  fitEven(&renderWidth, &renderHeight);
  const auto fpsRt = parseJsonTime(document["settings"]["fps"]);
  if (!fpsRt || fpsRt->num <= 0) throw std::runtime_error("invalid fps");
  AVRational fps{static_cast<int>(fpsRt->num), static_cast<int>(fpsRt->den)};
  const RationalTime seqDuration = snapshot.duration();

  emit(json{{"type", "started"},
            {"totalFrames",
             static_cast<int64_t>(seqDuration.toSeconds() * av_q2d(fps))},
            {"durationSeconds", seqDuration.toSeconds()},
            {"width", width},
            {"height", height}});

  // --- Output context -------------------------------------------------------
  AVFormatContext* outFmt = nullptr;
  // The container is chosen from the real filename, but the muxer must know it
  // is writing the .part file: faststart reopens `url` to move the moov atom.
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

  // Anything left behind by a failed run is removed by the caller of cleanup
  // on the error path (see the catch below).

  try {
    // --- Normalize analyses (AUD-16 / EXP-15) --------------------------------
    // Both pass before any encoding so measurement never interleaves with
    // the frame loop, and both measure exactly what this job will play:
    // the clips as trimmed, sped and ranged.
    const double exportStart = rangeStartSec;
    const double exportEnd = rangeEndSec > exportStart ? rangeEndSec
                                                       : seqDuration.toSeconds();

    std::map<std::string, double> levelGains;
    if (as.has_value() && as->levelClips) {
      const auto lufs =
          measureClipLoudnesses(document, media, exportStart,
                                exportEnd - exportStart,
                                static_cast<int>(kMixRate));
      levelGains = computeLevelGains(lufs);
      emit(json{{"type", "note"},
                {"message", "Leveling: " + std::to_string(levelGains.size()) +
                                " of " + std::to_string(lufs.size()) +
                                " audio clips adjusted"}});
    }

    std::map<std::string, double> exposureStops;
    if (vs.enabled && vs.matchExposure) {
      const auto luma =
          measureClipLuma(document, media, exportStart, exportEnd);
      exposureStops = computeExposureStops(luma);
      emit(json{{"type", "note"},
                {"message", "Exposure matching: " +
                                std::to_string(exposureStops.size()) + " of " +
                                std::to_string(luma.size()) +
                                " clips adjusted"}});
    }

    // --- Video encoder ------------------------------------------------------
    if (vs.enabled) {
      // EXP-5/6: software x264/x265/ProRes by default; hardware encoders are
      // opt-in per job and fall back to software when unavailable rather than
      // failing the export.
      std::vector<std::string> candidates;
      const bool hevc = vs.codec == "h265" || vs.codec == "hevc";
      if (vs.codec == "prores") {
        candidates = {"prores_ks", "prores"};
      } else if (vs.hardware) {
        candidates = hevc
            ? std::vector<std::string>{"hevc_videotoolbox", "hevc_nvenc",
                                       "hevc_qsv", "hevc_amf", "libx265"}
            : std::vector<std::string>{"h264_videotoolbox", "h264_nvenc",
                                       "h264_qsv", "h264_amf", "libx264"};
      } else {
        candidates = {hevc ? "libx265" : "libx264"};
      }
      const AVCodec* codec = nullptr;
      std::string name;
      for (const auto& candidate : candidates) {
        codec = avcodec_find_encoder_by_name(candidate.c_str());
        if (codec) {
          name = candidate;
          break;
        }
      }
      if (!codec) {
        throw std::runtime_error("encoder not found: " + candidates.front());
      }
      emit(json{{"type", "encoder"}, {"video", name}});
      vEnc = avcodec_alloc_context3(codec);
      vEnc->width = width;
      vEnc->height = height;
      vEnc->pix_fmt = AV_PIX_FMT_YUV420P;
      vEnc->color_range = AVCOL_RANGE_MPEG;
      vEnc->time_base = av_inv_q(fps);
      vEnc->framerate = fps;
      vEnc->gop_size = std::max(12, static_cast<int>(av_q2d(fps) * 2.0));
      vEnc->max_b_frames = 2;
      if (name == "libx264" || name == "libx265") {
        char crfStr[16];
        snprintf(crfStr, sizeof(crfStr), "%d", vs.crf);
        av_opt_set(vEnc->priv_data, "crf", crfStr, 0);
        av_opt_set(vEnc->priv_data, "preset", vs.preset.c_str(), 0);
      } else if (name.rfind("prores", 0) == 0) {
        vEnc->pix_fmt = AV_PIX_FMT_YUV422P10LE;
        av_opt_set_int(vEnc->priv_data, "profile", 2, 0);  // 422 Standard
      } else {
        // Hardware encoders reorder frames on their own schedule, and the
        // resulting DTS confuses the mp4 muxer here; delivery does not need
        // B-frames badly enough to fight it.
        vEnc->max_b_frames = 0;
        av_opt_set_int(vEnc->priv_data, "allow_frame_reordering", 0, 0);
        // They take a bitrate, not a CRF. Map the quality knob onto a
        // bits-per-pixel budget so the slider still means something.
        const double bpp = vs.crf <= 18 ? 0.20 : vs.crf <= 20 ? 0.14
                          : vs.crf <= 23 ? 0.10 : 0.06;
        vEnc->bit_rate = static_cast<int64_t>(width * height * av_q2d(fps) * bpp);
      }
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

      // One scale, from composited sequence size to the delivered size.
      toYuv = sws_getContext(renderWidth, renderHeight, AV_PIX_FMT_RGBA, width,
                             height, static_cast<AVPixelFormat>(vEnc->pix_fmt),
                             renderWidth == width ? SWS_BILINEAR : SWS_BICUBIC,
                             nullptr, nullptr, nullptr);
      if (!toYuv) throw std::runtime_error("rgba→yuv scaler init failed");
    }

    // --- Audio: pre-mix the whole sequence ---------------------------------
    // Preview and export share cc::mixTimeline, so the file carries exactly
    // the balance, fades and crossfades the monitor played (arch §1).
    AudioBuffer mix;
    if (as.has_value()) {
      const Error mixErr =
          mixTimeline(document, media, rangeStartSec,
                      (rangeEndSec > rangeStartSec ? rangeEndSec
                                                   : seqDuration.toSeconds()) -
                          rangeStartSec,
                      static_cast<int>(kMixRate), masterFromDocument(document),
                      &mix,
                      levelGains.empty() ? nullptr : &levelGains);
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
      // "pcm" in a preset means 24-bit PCM for the ProRes master (EXP-5).
      const std::string audioCodec =
          as->codec == "pcm" ? "pcm_s24le" : as->codec;
      const AVCodec* codec = avcodec_find_encoder_by_name(audioCodec.c_str());
      if (!codec) throw std::runtime_error("audio encoder not found: " + audioCodec);
      aEnc = avcodec_alloc_context3(codec);
      aEnc->sample_rate = static_cast<int>(kMixRate);
      AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
      av_channel_layout_copy(&aEnc->ch_layout, &stereo);
      aEnc->sample_fmt = codec->sample_fmts ? codec->sample_fmts[0]
                                            : AV_SAMPLE_FMT_FLTP;
      // PCM is uncompressed; a bitrate request would be meaningless.
      if (audioCodec.rfind("pcm", 0) != 0) aEnc->bit_rate = as->bitrate;
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
      av_freep(&outFmt->url);
      outFmt->url = av_strdup(partPath.c_str());
      if (avio_open(&outFmt->pb, partPath.c_str(), AVIO_FLAG_WRITE) < 0)
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

    const int64_t totalFrames = static_cast<int64_t>(
        std::max(0.0, exportEnd - exportStart) * av_q2d(fps) + 0.5);
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
      // PCM encoders accept any frame length and report frame_size 0.
      const int chunk = aEnc->frame_size > 0 ? aEnc->frame_size : 1024;
      while (drain || av_audio_fifo_size(fifo) >= chunk) {
        const int read = av_audio_fifo_read(fifo,
                                            reinterpret_cast<void**>(aFrame->data),
                                            chunk);
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
        if (av_audio_fifo_size(fifo) < chunk && !drain) break;
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
          exportStart + static_cast<double>(f) / av_q2d(fps));
      const Error err = renderFrame(document, t.normalized(), renderWidth,
                                    renderHeight, media, &canvas,
                                    exposureStops.empty() ? nullptr
                                                          : &exposureStops);
      if (err != Error::None) throw std::runtime_error("renderFrame failed");

      if (vEnc) {
        if (av_frame_make_writable(vFrame) < 0)
          throw std::runtime_error("frame not writable");
        const uint8_t* srcData[4] = {canvas.rgba.data(), nullptr, nullptr, nullptr};
        const int srcStride[4] = {canvas.width * 4, 0, 0, 0};
        sws_scale(toYuv, srcData, srcStride, 0, renderHeight, vFrame->data,
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
    // Close the file before renaming so the trailer is on disk.
    if (outFmt && !(outFmt->oformat->flags & AVFMT_NOFILE)) avio_closep(&outFmt->pb);
    std::error_code renameError;
    std::filesystem::rename(partPath, output, renameError);
    if (renameError) {
      throw std::runtime_error("cannot finalize output: " + renameError.message());
    }
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
    std::error_code ignored;
    std::filesystem::remove(partPath, ignored);  // no partial survives a failure
    throw;
  }
}

}  // namespace cc
