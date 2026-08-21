#include "media/probe.h"

#include <algorithm>
#include <cmath>

#include <nlohmann/json.hpp>

extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/pixdesc.h>
}

#include "core/log.h"
#include "core/time.h"

namespace cc {

namespace {

std::string rationalToString(const AVRational& r) {
  if (r.num == 0 || r.den == 0) {
    return "0/1";
  }
  return std::to_string(r.num) + "/" + std::to_string(r.den);
}

const int32_t* displayMatrixFor(const AVStream* stream) {
  const AVPacketSideData* sd = av_packet_side_data_get(stream->codecpar->coded_side_data,
                                                       stream->codecpar->nb_coded_side_data,
                                                       AV_PKT_DATA_DISPLAYMATRIX);
  if (!sd || sd->size < 9 * static_cast<int>(sizeof(int32_t))) {
    return nullptr;
  }
  return reinterpret_cast<const int32_t*>(sd->data);
}

int displayRotationDegrees(const AVStream* stream) {
  const int32_t* matrix = displayMatrixFor(stream);
  if (!matrix) {
    return 0;
  }
  const double angle = av_display_rotation_get(matrix);
  if (std::isnan(angle)) {
    return 0;
  }
  long rounded = std::lround(-angle);
  rounded = ((rounded % 360) + 360) % 360;
  if (rounded > 180) {
    rounded -= 360;
  }
  return static_cast<int>(rounded);
}

const char* hdrName(const AVStream* stream) {
  switch (stream->codecpar->color_trc) {
    case AVCOL_TRC_SMPTE2084: return "hdr10";
    case AVCOL_TRC_ARIB_STD_B67: return "hlg";
    default: return "none";
  }
}

}  // namespace

Error probeFile(const std::string& path, std::string* outJson) {
  if (!outJson || path.empty()) {
    setLastError("probeFile: invalid arguments");
    return Error::InvalidArgument;
  }

  AVFormatContext* format = nullptr;
  int ret = avformat_open_input(&format, path.c_str(), nullptr, nullptr);
  if (ret < 0) {
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(ret, buf, sizeof(buf));
    setLastError(std::string("open failed: ") + buf);
    return Error::MediaOpenFailed;
  }
  ret = avformat_find_stream_info(format, nullptr);
  if (ret < 0) {
    avformat_close_input(&format);
    setLastError("find_stream_info failed");
    return Error::MediaOpenFailed;
  }

  nlohmann::json j;
  j["formatName"] = format->iformat ? format->iformat->name : "";

  double durationSeconds = 0.0;
  if (format->duration > 0) {
    durationSeconds = static_cast<double>(format->duration) / AV_TIME_BASE;
  } else {
    for (unsigned i = 0; i < format->nb_streams; ++i) {
      const AVStream* s = format->streams[i];
      if (s->duration > 0 && s->time_base.den > 0) {
        durationSeconds = std::max(durationSeconds,
                                   static_cast<double>(s->duration) * av_q2d(s->time_base));
      }
    }
  }
  const RationalTime duration = RationalTime::fromSeconds(durationSeconds);
  j["duration"] = duration.toString();
  j["durationSeconds"] = durationSeconds;
  j["bitrate"] = format->bit_rate > 0 ? format->bit_rate : 0;

  const AVStream* video = nullptr;
  const AVStream* audio = nullptr;
  for (unsigned i = 0; i < format->nb_streams; ++i) {
    const AVStream* s = format->streams[i];
    if (!video && s->codecpar->codec_type == AVMEDIA_TYPE_VIDEO &&
        s->codecpar->width > 0) {
      video = s;
    }
    if (!audio && s->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
      audio = s;
    }
  }

  bool isImage = false;
  if (video) {
    nlohmann::json v;
    v["width"] = video->codecpar->width;
    v["height"] = video->codecpar->height;
    v["codec"] = avcodec_get_name(video->codecpar->codec_id);
    v["pixFmt"] = av_get_pix_fmt_name(static_cast<AVPixelFormat>(video->codecpar->format));

    AVRational fps = video->avg_frame_rate;
    if (fps.num <= 0 || fps.den <= 0) {
      fps = video->r_frame_rate;
    }
    v["fps"] = rationalToString(fps);

    const AVRational& rf = video->r_frame_rate;
    bool vfr = false;
    if (fps.num > 0 && rf.num > 0) {
      const double a = av_q2d(fps);
      const double b = av_q2d(rf);
      vfr = std::fabs(a - b) / std::max(a, 1.0) > 0.02;
    }
    v["vfr"] = vfr;
    v["rotation"] = displayRotationDegrees(video);
    v["hdr"] = hdrName(video);
    j["video"] = v;

    const std::string fmtName = format->iformat ? format->iformat->name : "";
    isImage = durationSeconds <= 0.15 &&
              (fmtName.find("image2") != std::string::npos ||
               video->codecpar->codec_id == AV_CODEC_ID_PNG ||
               video->codecpar->codec_id == AV_CODEC_ID_MJPEG);
  } else {
    j["video"] = nullptr;
  }

  if (audio) {
    nlohmann::json a;
    a["codec"] = avcodec_get_name(audio->codecpar->codec_id);
    a["sampleRate"] = audio->codecpar->sample_rate;
    a["channels"] = audio->codecpar->ch_layout.nb_channels;
    char layout[64] = {0};
    if (av_channel_layout_describe(&audio->codecpar->ch_layout, layout, sizeof(layout)) >= 0) {
      a["layout"] = layout;
    }
    j["audio"] = a;
  } else {
    j["audio"] = nullptr;
  }

  j["type"] = isImage ? "image" : (video ? "video" : (audio ? "audio" : "unknown"));

  avformat_close_input(&format);
  *outJson = j.dump();
  return Error::None;
}

}  // namespace cc
