#include "media/frame.h"

#include <cmath>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
}

#include "core/log.h"
#include "core/result.h"

namespace cc {

namespace {

struct DecoderSession {
  AVFormatContext* format = nullptr;
  AVCodecContext* codec = nullptr;
  int streamIndex = -1;
  AVStream* stream = nullptr;

  ~DecoderSession() {
    if (codec) avcodec_free_context(&codec);
    if (format) avformat_close_input(&format);
  }
};

Error openVideoDecoder(const std::string& path, DecoderSession* session) {
  int ret = avformat_open_input(&session->format, path.c_str(), nullptr, nullptr);
  if (ret < 0) {
    setLastError("cannot open media: " + path);
    return Error::MediaOpenFailed;
  }
  ret = avformat_find_stream_info(session->format, nullptr);
  if (ret < 0) {
    setLastError("find_stream_info failed");
    return Error::MediaOpenFailed;
  }
  const AVCodec* decoder = nullptr;
  session->streamIndex = av_find_best_stream(session->format, AVMEDIA_TYPE_VIDEO, -1, -1,
                                             &decoder, 0);
  if (session->streamIndex < 0 || !decoder) {
    setLastError("no video stream");
    return Error::MediaNoStream;
  }
  session->stream = session->format->streams[session->streamIndex];
  session->codec = avcodec_alloc_context3(decoder);
  avcodec_parameters_to_context(session->codec, session->stream->codecpar);
  ret = avcodec_open2(session->codec, decoder, nullptr);
  if (ret < 0) {
    setLastError("decoder open failed");
    return Error::MediaDecodeFailed;
  }
  return Error::None;
}

int displayRotationFor(const AVStream* stream) {
  const AVPacketSideData* sd = av_packet_side_data_get(stream->codecpar->coded_side_data,
                                                       stream->codecpar->nb_coded_side_data,
                                                       AV_PKT_DATA_DISPLAYMATRIX);
  if (!sd || sd->size < 9 * static_cast<int>(sizeof(int32_t))) {
    return 0;
  }
  const auto* matrix = reinterpret_cast<const int32_t*>(sd->data);
  const double angle = av_display_rotation_get(matrix);
  if (std::isnan(angle)) {
    return 0;
  }
  long rounded = std::lround(-angle);
  rounded = ((rounded % 360) + 360) % 360;
  if (rounded > 180) rounded -= 360;
  return static_cast<int>(rounded);
}

void rotateRgba(std::vector<uint8_t>* data, int* width, int* height, int degrees) {
  const int w = *width;
  const int h = *height;
  if (degrees == 90 || degrees == -90 || degrees == 270) {
    std::vector<uint8_t> rotated(data->size());
    for (int y = 0; y < h; ++y) {
      for (int x = 0; x < w; ++x) {
        int nx = 0, ny = 0;
        if (degrees == 90) {
          nx = h - 1 - y;
          ny = x;
        } else {
          nx = y;
          ny = w - 1 - x;
        }
        const size_t src = (static_cast<size_t>(y) * w + x) * 4;
        const size_t dst = (static_cast<size_t>(ny) * h + nx) * 4;
        rotated[dst + 0] = (*data)[src + 0];
        rotated[dst + 1] = (*data)[src + 1];
        rotated[dst + 2] = (*data)[src + 2];
        rotated[dst + 3] = (*data)[src + 3];
      }
    }
    *data = std::move(rotated);
    std::swap(*width, *height);
  } else if (degrees == 180) {
    for (size_t i = 0; i < data->size() / 2; i += 4) {
      const size_t j = data->size() - 4 - i;
      for (int c = 0; c < 4; ++c) std::swap((*data)[i + c], (*data)[j + c]);
    }
  }
}

Error decodeFrameNear(DecoderSession* s, double seconds, AVFrame** outFrame) {
  AVRational tb = s->stream->time_base;
  const double frameDur = s->stream->avg_frame_rate.num > 0
                              ? av_q2d(av_inv_q(s->stream->avg_frame_rate))
                              : 1.0 / 30.0;

  const int64_t targetTs = static_cast<int64_t>(seconds / av_q2d(tb));
  if (seconds > 0.5) {
    if (avformat_seek_file(s->format, s->streamIndex, INT64_MIN, targetTs, targetTs, 0) < 0) {
      av_seek_frame(s->format, -1, 0, AVSEEK_FLAG_BACKWARD);
    }
  } else {
    av_seek_frame(s->format, -1, 0, AVSEEK_FLAG_BACKWARD);
  }
  avcodec_flush_buffers(s->codec);

  AVPacket* pkt = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  Error result = Error::MediaDecodeFailed;
  int framesSinceSeek = 0;
  const double epsilon = frameDur * 0.5;

  while (true) {
    bool decodedAny = false;
    while (avcodec_receive_frame(s->codec, frame) == 0) {
      decodedAny = true;
      ++framesSinceSeek;
      double ptsSec = -1.0;
      if (frame->pts != AV_NOPTS_VALUE) {
        ptsSec = static_cast<double>(frame->pts) * av_q2d(tb);
      }
      if (ptsSec < 0 || ptsSec >= seconds - epsilon || framesSinceSeek > 600) {
        *outFrame = frame;
        av_packet_free(&pkt);
        return Error::None;
      }
      av_frame_unref(frame);
    }

    int ret = av_read_frame(s->format, pkt);
    if (ret < 0) {
      if (decodedAny || framesSinceSeek > 0) {
        avcodec_send_packet(s->codec, nullptr);
        continue;
      }
      break;
    }
    if (pkt->stream_index == s->streamIndex) {
      if (avcodec_send_packet(s->codec, pkt) < 0) {
        result = Error::MediaDecodeFailed;
        break;
      }
    }
    av_packet_unref(pkt);
  }

  av_frame_free(&frame);
  av_packet_free(&pkt);
  setLastError("no decodable frame found near requested time");
  return result;
}

}  // namespace

Error extractFrameRgba(const std::string& path, double seconds, int targetWidth,
                       DecodedFrame* outFrame) {
  if (!outFrame || path.empty()) {
    setLastError("extractFrameRgba: invalid arguments");
    return Error::InvalidArgument;
  }
  seconds = std::max(0.0, seconds);

  DecoderSession session;
  Error err = openVideoDecoder(path, &session);
  if (err != Error::None) return err;

  AVFrame* frame = nullptr;
  err = decodeFrameNear(&session, seconds, &frame);
  if (err != Error::None) return err;

  const int srcW = frame->width;
  const int srcH = frame->height;
  int dstW = targetWidth > 0 ? targetWidth : srcW;
  dstW -= dstW % 2;
  int dstH = static_cast<int>(std::llround(static_cast<double>(srcH) * dstW / srcW));
  dstH -= dstH % 2;
  if (dstW <= 0 || dstH <= 0) {
    av_frame_free(&frame);
    setLastError("degenerate output size");
    return Error::InvalidArgument;
  }

  SwsContext* sws = sws_getContext(srcW, srcH, static_cast<AVPixelFormat>(frame->format),
                                   dstW, dstH, AV_PIX_FMT_RGBA, SWS_BILINEAR, nullptr,
                                   nullptr, nullptr);
  if (!sws) {
    av_frame_free(&frame);
    setLastError("sws_getContext failed");
    return Error::InternalError;
  }

  outFrame->rgba.assign(static_cast<size_t>(dstW) * dstH * 4, 0);
  uint8_t* dstData[4] = {outFrame->rgba.data(), nullptr, nullptr, nullptr};
  int dstLinesize[4] = {dstW * 4, 0, 0, 0};
  sws_scale(sws, frame->data, frame->linesize, 0, srcH, dstData, dstLinesize);
  sws_freeContext(sws);

  const int rotation = displayRotationFor(session.stream);
  av_frame_free(&frame);

  outFrame->width = dstW;
  outFrame->height = dstH;
  rotateRgba(&outFrame->rgba, &outFrame->width, &outFrame->height, rotation);
  return Error::None;
}

Error extractThumbnailJpeg(const std::string& path, double seconds, int width,
                           std::vector<uint8_t>* outJpeg) {
  if (!outJpeg || path.empty()) {
    setLastError("extractThumbnailJpeg: invalid arguments");
    return Error::InvalidArgument;
  }
  DecodedFrame frame;
  Error err = extractFrameRgba(path, seconds, width, &frame);
  if (err != Error::None) return err;

  const AVCodec* encoder = avcodec_find_encoder(AV_CODEC_ID_MJPEG);
  if (!encoder) {
    setLastError("mjpeg encoder unavailable");
    return Error::EncodeFailed;
  }
  AVCodecContext* enc = avcodec_alloc_context3(encoder);
  enc->width = frame.width;
  enc->height = frame.height;
  enc->pix_fmt = AV_PIX_FMT_YUVJ420P;
  enc->time_base = AVRational{1, 1};
  av_opt_set_int(enc->priv_data, "qscale", 3, 0);
  if (avcodec_open2(enc, encoder, nullptr) < 0) {
    avcodec_free_context(&enc);
    setLastError("mjpeg encoder open failed");
    return Error::EncodeFailed;
  }

  AVFrame* yuv = av_frame_alloc();
  yuv->format = enc->pix_fmt;
  yuv->width = enc->width;
  yuv->height = enc->height;
  av_frame_get_buffer(yuv, 32);

  SwsContext* sws = sws_getContext(frame.width, frame.height, AV_PIX_FMT_RGBA, yuv->width,
                                   yuv->height, enc->pix_fmt, SWS_BILINEAR, nullptr, nullptr,
                                   nullptr);
  uint8_t* srcData[4] = {const_cast<uint8_t*>(frame.rgba.data()), nullptr, nullptr, nullptr};
  int srcLinesize[4] = {frame.width * 4, 0, 0, 0};
  sws_scale(sws, srcData, srcLinesize, 0, frame.height, yuv->data, yuv->linesize);
  sws_freeContext(sws);

  yuv->pts = 0;
  err = Error::EncodeFailed;
  if (avcodec_send_frame(enc, yuv) == 0) {
    AVPacket* pkt = av_packet_alloc();
    while (avcodec_receive_packet(enc, pkt) == 0) {
      outJpeg->insert(outJpeg->end(), pkt->data, pkt->data + pkt->size);
      err = Error::None;
      av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
  }
  if (err != Error::None) setLastError("mjpeg encode produced no packet");

  av_frame_free(&yuv);
  avcodec_free_context(&enc);
  return err;
}

}  // namespace cc
