#include <chrono>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <nlohmann/json.hpp>
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

using nlohmann::json;

namespace {

void emit(const json& line) {
  std::cout << line.dump() << "\n";
  std::cout.flush();
}

void emitFail(const std::string& message) { emit(json{{"type", "fail"}, {"error", message}}); }

struct VideoSettings {
  std::string codec = "h264";
  int crf = 18;
  std::string preset = "medium";
  bool enabled = true;
  // 0 = keep the source size. Proxy jobs set maxHeight (arch §5: 960x540
  // equivalent) and the encoder scales while preserving aspect.
  int maxWidth = 0;
  int maxHeight = 0;
};

struct AudioSettings {
  std::string codec = "aac";
  int bitrate = 320000;
  bool enabled = true;
};

struct Job {
  std::string input;
  std::string output;
  VideoSettings video;
  std::optional<AudioSettings> audio{AudioSettings{}};
  bool faststart = true;
};

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

Job loadJob(const json& j) {
  Job job;
  job.input = j.at("input").get<std::string>();
  job.output = j.at("output").get<std::string>();
  if (j.contains("video")) {
    const auto& v = j["video"];
    if (v.is_null()) {
      job.video.enabled = false;
    } else {
      if (v.contains("codec")) job.video.codec = v["codec"].get<std::string>();
      if (v.contains("crf")) job.video.crf = v["crf"].get<int>();
      if (v.contains("preset")) job.video.preset = v["preset"].get<std::string>();
      if (v.contains("maxWidth")) job.video.maxWidth = v["maxWidth"].get<int>();
      if (v.contains("maxHeight")) job.video.maxHeight = v["maxHeight"].get<int>();
    }
  }
  if (j.contains("audio")) {
    const auto& a = j["audio"];
    if (a.is_null()) {
      job.audio.reset();
    } else {
      if (a.contains("codec")) job.audio->codec = a["codec"].get<std::string>();
      if (a.contains("bitrate")) job.audio->bitrate = a["bitrate"].get<int>();
    }
  }
  if (j.contains("faststart")) job.faststart = j["faststart"].get<bool>();
  return job;
}

// Scales (width, height) down so neither exceeds the caps, keeping aspect and
// landing on even dimensions that yuv420p requires.
void fitInside(int maxW, int maxH, int* width, int* height) {
  double scale = 1.0;
  if (maxW > 0 && *width > maxW) scale = static_cast<double>(maxW) / *width;
  if (maxH > 0 && *height > maxH) {
    const double s = static_cast<double>(maxH) / *height;
    if (s < scale) scale = s;
  }
  if (scale >= 1.0) return;
  int w = static_cast<int>(*width * scale + 0.5);
  int h = static_cast<int>(*height * scale + 0.5);
  *width = w < 2 ? 2 : w;
  *height = h < 2 ? 2 : h;
}

AVCodecContext* openEncoder(const AVCodec* codec, AVCodecContext* sourceVideo,
                            AVRational fps, const VideoSettings& settings) {
  AVCodecContext* enc = avcodec_alloc_context3(codec);
  int width = sourceVideo->width;
  int height = sourceVideo->height;
  fitInside(settings.maxWidth, settings.maxHeight, &width, &height);
  enc->width = width - width % 2;
  enc->height = height - height % 2;
  enc->pix_fmt = AV_PIX_FMT_YUV420P;
  enc->time_base = av_inv_q(fps);
  enc->framerate = fps;
  enc->gop_size = static_cast<int>(av_q2d(fps) * 2.0);
  if (enc->gop_size < 12) enc->gop_size = 12;
  enc->max_b_frames = 2;
  return enc;
}

int run(const Job& job) {
  const auto clockStart = std::chrono::steady_clock::now();

  AVFormatContext* inFmt = nullptr;
  int ret = avformat_open_input(&inFmt, job.input.c_str(), nullptr, nullptr);
  if (ret < 0) throw std::runtime_error("cannot open input");
  ret = avformat_find_stream_info(inFmt, nullptr);
  if (ret < 0) throw std::runtime_error("find_stream_info failed");

  int vIdx = av_find_best_stream(inFmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
  int aIdx = av_find_best_stream(inFmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);

  double durationSec = inFmt->duration > 0 ? static_cast<double>(inFmt->duration) / AV_TIME_BASE
                                           : 0.0;
  AVRational srcFps{30, 1};
  if (vIdx >= 0 && inFmt->streams[vIdx]->avg_frame_rate.num > 0) {
    srcFps = inFmt->streams[vIdx]->avg_frame_rate;
  }
  int64_t totalFrames =
      durationSec > 0 ? static_cast<int64_t>(durationSec * av_q2d(srcFps)) : 0;
  emit(json{{"type", "started"}, {"totalFrames", totalFrames},
            {"durationSeconds", durationSec}});

  AVFormatContext* outFmt = nullptr;
  ret = avformat_alloc_output_context2(&outFmt, nullptr, nullptr, job.output.c_str());
  if (ret < 0) throw std::runtime_error("cannot create output context");

  AVCodecContext* vDec = nullptr;
  AVCodecContext* vEnc = nullptr;
  AVStream* vOut = nullptr;
  SwsContext* swsV = nullptr;
  AVFrame* vFrameIn = nullptr;
  AVFrame* vFrameOut = nullptr;
  int64_t lastVPts = -1;

  AVCodecContext* aDec = nullptr;
  AVCodecContext* aEnc = nullptr;
  AVStream* aOut = nullptr;
  SwrContext* swrA = nullptr;
  AVAudioFifo* fifo = nullptr;
  AVFrame* aFrameOut = nullptr;
  int64_t samplesWritten = 0;

  auto cleanup = [&]() {
    if (vDec) avcodec_free_context(&vDec);
    if (vEnc) avcodec_free_context(&vEnc);
    if (vFrameIn) av_frame_free(&vFrameIn);
    if (vFrameOut) av_frame_free(&vFrameOut);
    if (swsV) sws_freeContext(swsV);
    if (aDec) avcodec_free_context(&aDec);
    if (aEnc) avcodec_free_context(&aEnc);
    if (aFrameOut) av_frame_free(&aFrameOut);
    if (fifo) av_audio_fifo_free(fifo);
    if (swrA) swr_free(&swrA);
    if (inFmt) avformat_close_input(&inFmt);
    if (outFmt && !(outFmt->oformat->flags & AVFMT_NOFILE)) avio_closep(&outFmt->pb);
    if (outFmt) avformat_free_context(outFmt);
  };

  try {
    if (job.video.enabled && vIdx >= 0) {
      const AVStream* vs = inFmt->streams[vIdx];
      const AVCodec* decoder = avcodec_find_decoder(vs->codecpar->codec_id);
      if (!decoder) throw std::runtime_error("video decoder not found");
      vDec = avcodec_alloc_context3(decoder);
      avcodec_parameters_to_context(vDec, vs->codecpar);
      if (avcodec_open2(vDec, decoder, nullptr) < 0)
        throw std::runtime_error("video decoder open failed");

      std::string encoderName = job.video.codec == "h265" || job.video.codec == "hevc"
                                    ? "libx265"
                                    : "libx264";
      const AVCodec* encoder = avcodec_find_encoder_by_name(encoderName.c_str());
      if (!encoder) throw std::runtime_error("encoder not found: " + encoderName);

      vEnc = openEncoder(encoder, vDec, srcFps, job.video);
      char crfStr[16];
      snprintf(crfStr, sizeof(crfStr), "%d", job.video.crf);
      av_opt_set(vEnc->priv_data, "crf", crfStr, 0);
      av_opt_set(vEnc->priv_data, "preset", job.video.preset.c_str(), 0);

      if (outFmt->oformat->flags & AVFMT_GLOBALHEADER)
        vEnc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
      if (avcodec_open2(vEnc, encoder, nullptr) < 0)
        throw std::runtime_error("video encoder open failed");

      vOut = avformat_new_stream(outFmt, nullptr);
      avcodec_parameters_from_context(vOut->codecpar, vEnc);
      vOut->time_base = vEnc->time_base;

      vFrameIn = av_frame_alloc();
      vFrameOut = av_frame_alloc();
      vFrameOut->format = vEnc->pix_fmt;
      vFrameOut->width = vEnc->width;
      vFrameOut->height = vEnc->height;
      if (av_frame_get_buffer(vFrameOut, 32) < 0)
        throw std::runtime_error("video frame buffer alloc failed");

      swsV = sws_getContext(vDec->width, vDec->height,
                            static_cast<AVPixelFormat>(vDec->pix_fmt), vEnc->width,
                            vEnc->height, vEnc->pix_fmt, SWS_BILINEAR, nullptr, nullptr,
                            nullptr);
      if (!swsV) throw std::runtime_error("scaler init failed");
    }

    if (job.audio.has_value() && aIdx >= 0) {
      const AVStream* as = inFmt->streams[aIdx];
      const AVCodec* decoder = avcodec_find_decoder(as->codecpar->codec_id);
      if (!decoder) throw std::runtime_error("audio decoder not found");
      aDec = avcodec_alloc_context3(decoder);
      avcodec_parameters_to_context(aDec, as->codecpar);
      if (avcodec_open2(aDec, decoder, nullptr) < 0)
        throw std::runtime_error("audio decoder open failed");

      const AVCodec* encoder = avcodec_find_encoder_by_name(job.audio->codec.c_str());
      if (!encoder) throw std::runtime_error("audio encoder not found: " + job.audio->codec);
      aEnc = avcodec_alloc_context3(encoder);
      aEnc->sample_rate = aDec->sample_rate > 0 ? aDec->sample_rate : 48000;
      av_channel_layout_copy(&aEnc->ch_layout, &aDec->ch_layout);
      if (aEnc->ch_layout.nb_channels == 0) av_channel_layout_default(&aEnc->ch_layout, 2);
      aEnc->sample_fmt = encoder->sample_fmts ? encoder->sample_fmts[0] : AV_SAMPLE_FMT_FLTP;
      aEnc->bit_rate = job.audio->bitrate;
      if (outFmt->oformat->flags & AVFMT_GLOBALHEADER)
        aEnc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
      if (avcodec_open2(aEnc, encoder, nullptr) < 0)
        throw std::runtime_error("audio encoder open failed");

      aOut = avformat_new_stream(outFmt, nullptr);
      avcodec_parameters_from_context(aOut->codecpar, aEnc);
      aOut->time_base = AVRational{1, aEnc->sample_rate};

      swr_alloc_set_opts2(&swrA, &aEnc->ch_layout, aEnc->sample_fmt, aEnc->sample_rate,
                          &aDec->ch_layout, static_cast<AVSampleFormat>(aDec->sample_fmt),
                          aDec->sample_rate, 0, nullptr);
      if (!swrA || swr_init(swrA) < 0) throw std::runtime_error("resampler init failed");

      fifo = av_audio_fifo_alloc(aEnc->sample_fmt, aEnc->ch_layout.nb_channels,
                                 aEnc->frame_size * 4);
      if (!fifo) throw std::runtime_error("audio fifo alloc failed");

      aFrameOut = av_frame_alloc();
      aFrameOut->format = aEnc->sample_fmt;
      aFrameOut->ch_layout = aEnc->ch_layout;
      aFrameOut->sample_rate = aEnc->sample_rate;
      aFrameOut->nb_samples = aEnc->frame_size;
      if (av_frame_get_buffer(aFrameOut, 0) < 0)
        throw std::runtime_error("audio frame buffer alloc failed");
    }

    if (!(outFmt->oformat->flags & AVFMT_NOFILE)) {
      ret = avio_open(&outFmt->pb, job.output.c_str(), AVIO_FLAG_WRITE);
      if (ret < 0) throw std::runtime_error("cannot open output for writing");
    }

    AVDictionary* opts = nullptr;
    if (job.faststart) av_dict_set(&opts, "movflags", "+faststart", 0);
    ret = avformat_write_header(outFmt, &opts);
    av_dict_free(&opts);
    if (ret < 0) throw std::runtime_error("write_header failed");

    auto writePacket = [&](AVPacket* pkt, AVCodecContext* enc, AVStream* stream) {
      av_packet_rescale_ts(pkt, enc->time_base, stream->time_base);
      pkt->stream_index = stream->index;
      if (av_interleaved_write_frame(outFmt, pkt) < 0)
        throw std::runtime_error("mux write failed");
    };

    auto encodeVideoFrame = [&](AVFrame* frame, int64_t frameCount) {
      if (frame) {
        if (frame->pts != AV_NOPTS_VALUE) {
          int64_t pts = av_rescale_q(frame->pts, inFmt->streams[vIdx]->time_base,
                                     vEnc->time_base);
          pts = pts <= lastVPts ? lastVPts + 1 : pts;
          frame->pts = pts;
        } else {
          frame->pts = lastVPts + 1;
        }
        lastVPts = frame->pts;
      }
      if (avcodec_send_frame(vEnc, frame) < 0) throw std::runtime_error("send_frame failed");
      AVPacket* pkt = av_packet_alloc();
      while (avcodec_receive_packet(vEnc, pkt) == 0) {
        writePacket(pkt, vEnc, vOut);
        if (totalFrames > 0 && frameCount % 30 == 0) {
          emit(json{{"type", "progress"},
                    {"frame", frameCount},
                    {"totalFrames", totalFrames},
                    {"percent",
                     std::min(100.0, 100.0 * static_cast<double>(frameCount) /
                                         static_cast<double>(totalFrames))}});
        }
        av_packet_unref(pkt);
      }
      av_packet_free(&pkt);
    };

    auto drainAudioToFifo = [&](uint8_t** convertedInput, int convertedSamples) {
      if (convertedSamples < 0) convertedSamples = 0;
      if (convertedSamples > 0 &&
          av_audio_fifo_realloc(fifo, av_audio_fifo_size(fifo) + convertedSamples) < 0) {
        throw std::runtime_error("fifo realloc failed");
      }
      if (convertedSamples > 0) {
        if (av_audio_fifo_write(fifo, reinterpret_cast<void**>(convertedInput),
                                convertedSamples) < convertedSamples) {
          throw std::runtime_error("fifo write failed");
        }
      }
    };

    auto encodeQueuedAudio = [&](bool drain) {
      AVPacket* pkt = av_packet_alloc();
      while (drain || av_audio_fifo_size(fifo) >= aEnc->frame_size) {
        const int read = av_audio_fifo_read(
            fifo, reinterpret_cast<void**>(aFrameOut->data), aEnc->frame_size);
        if (read <= 0) break;
        aFrameOut->nb_samples = read;
        aFrameOut->pts = samplesWritten;
        samplesWritten += read;
        if (avcodec_send_frame(aEnc, aFrameOut) < 0) {
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

    AVPacket* pkt = av_packet_alloc();
    AVFrame* decFrame = av_frame_alloc();
    int encodedFrames = 0;
    while (true) {
      ret = av_read_frame(inFmt, pkt);
      if (ret < 0) break;

      if (vIdx >= 0 && pkt->stream_index == vIdx && vEnc) {
        if (avcodec_send_packet(vDec, pkt) == 0) {
          while (avcodec_receive_frame(vDec, decFrame) == 0) {
            if (av_frame_make_writable(vFrameOut) == 0) {
              sws_scale(swsV, decFrame->data, decFrame->linesize, 0, decFrame->height,
                        vFrameOut->data, vFrameOut->linesize);
              vFrameOut->pts = decFrame->pts;
              encodeVideoFrame(vFrameOut, ++encodedFrames);
            }
            av_frame_unref(decFrame);
          }
        }
      } else if (aIdx >= 0 && pkt->stream_index == aIdx && aEnc) {
        if (avcodec_send_packet(aDec, pkt) == 0) {
          while (avcodec_receive_frame(aDec, decFrame) == 0) {
            const int nch = aEnc->ch_layout.nb_channels;
            const int bps = av_get_bytes_per_sample(aEnc->sample_fmt);
            std::vector<uint8_t> convBuf(static_cast<size_t>(decFrame->nb_samples) * nch *
                                         bps);
            uint8_t* planes[8] = {nullptr};
            if (av_sample_fmt_is_planar(aEnc->sample_fmt)) {
              for (int c = 0; c < nch; ++c) {
                planes[c] = convBuf.data() +
                            static_cast<size_t>(c) * decFrame->nb_samples * bps;
              }
            } else {
              planes[0] = convBuf.data();
            }
            const int convSamples = swr_convert(swrA, planes, decFrame->nb_samples,
                                                const_cast<const uint8_t**>(decFrame->data),
                                                decFrame->nb_samples);
            drainAudioToFifo(planes, convSamples);
            encodeQueuedAudio(false);
            av_frame_unref(decFrame);
          }
        }
      }
      av_packet_unref(pkt);
    }

    if (vEnc) {
      encodeVideoFrame(nullptr, encodedFrames);
    }
    if (aEnc) {
      drainAudioToFifo(nullptr, 0);
      encodeQueuedAudio(true);
      avcodec_send_frame(aEnc, nullptr);
      AVPacket* pktFlush = av_packet_alloc();
      while (avcodec_receive_packet(aEnc, pktFlush) == 0) {
        writePacket(pktFlush, aEnc, aOut);
        av_packet_unref(pktFlush);
      }
      av_packet_free(&pktFlush);
    }

    av_write_trailer(outFmt);
    av_packet_free(&pkt);
    av_frame_free(&decFrame);

    const double elapsed =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - clockStart).count();
    int64_t bytes = 0;
    FILE* f = fopen(job.output.c_str(), "rb");
    if (f) {
      fseek(f, 0, SEEK_END);
      bytes = ftell(f);
      fclose(f);
    }
    cleanup();
    emit(json{{"type", "done"}, {"seconds", elapsed}, {"bytes", bytes}});
    return 0;
  } catch (...) {
    cleanup();
    throw;
  }
}

}  // namespace

int main(int argc, char** argv) {
  std::string jobPath;
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--job") == 0 && i + 1 < argc) {
      jobPath = argv[++i];
    }
  }
  if (jobPath.empty()) {
    emitFail("usage: crazycut_worker --job <job.json>");
    return 2;
  }

  av_log_set_level(AV_LOG_ERROR);

  try {
    const Job job = loadJob(parseJobFile(jobPath));
    return run(job);
  } catch (const std::exception& e) {
    emitFail(e.what());
    return 1;
  } catch (...) {
    emitFail("unknown error");
    return 1;
  }
}
