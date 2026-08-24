#include "media/frame.h"

#include <cmath>
#include <list>
#include <memory>

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

// An open decoder plus the state that makes repeated, mostly-forward reads
// cheap: the frame we last handed out and the scaler configured for it.
// Sessions live in a small per-thread LRU (see acquireDecoder) so scrubbing and
// playback reuse one open file instead of reopening it for every frame.
struct DecoderSession {
  std::string path;
  AVFormatContext* format = nullptr;
  AVCodecContext* codec = nullptr;
  int streamIndex = -1;
  AVStream* stream = nullptr;

  AVFrame* held = nullptr;      // last decoded frame, owned here
  // avcodec_receive_frame unrefs its destination before it decides whether it
  // has a frame, so decoding straight into `held` destroys the frame we are
  // still holding whenever the call comes back EAGAIN or EOF. Receive into
  // `scratch` and move into `held` only on success.
  AVFrame* scratch = nullptr;
  bool heldValid = false;
  double heldPtsSec = -1.0;

  SwsContext* sws = nullptr;
  int swsSrcW = 0, swsSrcH = 0, swsSrcFmt = -1, swsDstW = 0, swsDstH = 0;

  // A still image decodes to the same pixels at every timeline instant, so the
  // scaled RGBA is kept and handed back for the rest of the clip. Without this
  // an animated photo re-ran a full decode + swscale of the original (often
  // 12-24 megapixel) file on every preview frame, which is the single largest
  // cost in playing a keyframed image clip.
  bool still = false;
  std::vector<uint8_t> stillRgba;
  int stillW = 0, stillH = 0;
  int stillTargetWidth = -1;

  ~DecoderSession() {
    if (sws) sws_freeContext(sws);
    if (scratch) av_frame_free(&scratch);
    if (held) av_frame_free(&held);
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
  // Decoding is the export's second-largest cost and every frame of it ran on
  // one core. Frame threading is what makes a 4K H.264/HEVC source keep up;
  // slice threading covers the codecs that cannot frame-thread. 0 = one thread
  // per core, which the decoder scales down when the stream cannot use them.
  session->codec->thread_count = 0;
  session->codec->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
  ret = avcodec_open2(session->codec, decoder, nullptr);
  if (ret < 0) {
    setLastError("decoder open failed");
    return Error::MediaDecodeFailed;
  }
  // Same rule the prober uses to call a file an image (media/probe.cpp): the
  // single-image demuxers, plus the still codecs by id for containers that do
  // not name themselves. GIF stays out of this cache because its frames must
  // be decoded at their requested timestamps.
  const std::string fmtName =
      session->format->iformat ? session->format->iformat->name : "";
  const AVCodecID codecId = session->stream->codecpar->codec_id;
  session->still = fmtName.find("image2") != std::string::npos ||
                   fmtName.find("_pipe") != std::string::npos ||
                   codecId == AV_CODEC_ID_PNG || codecId == AV_CODEC_ID_MJPEG ||
                   codecId == AV_CODEC_ID_WEBP;
  return Error::None;
}

// Up to this many decoders stay open per thread, and up to this many of them
// may be reading one file at different points in it.
constexpr size_t kMaxCachedDecoders = 8;
constexpr size_t kMaxSessionsPerPath = 4;

std::list<std::unique_ptr<DecoderSession>>& decoderCache() {
  // Thread-local so preview (UI thread) and export workers never contend.
  thread_local std::list<std::unique_ptr<DecoderSession>> cache;
  return cache;
}

double frameDurationOf(const DecoderSession* s) {
  if (s->stream->avg_frame_rate.num > 0)
    return av_q2d(av_inv_q(s->stream->avg_frame_rate));
  return 1.0 / 30.0;
}

// Can this session reach [seconds] by decoding forward, the cheap case that
// decodeFrameNear takes without seeking?
bool canReachForward(const DecoderSession* s, double seconds) {
  if (!s->heldValid || !s->held || s->held->width <= 0 || s->heldPtsSec < 0) {
    return false;
  }
  const double frameDur = frameDurationOf(s);
  return seconds >= s->heldPtsSec - frameDur * 0.5 &&
         seconds - s->heldPtsSec <= 2.0;
}

// Returns an open session positioned to serve [path] at [seconds], reusing a
// cached one when that is cheap and opening another when it is not. The
// returned pointer stays valid until the next acquireDecoder call on this
// thread evicts it.
//
// Keying purely on the path was pathological whenever two clips read the same
// file at once — a picture-in-picture, a cutaway from the same recording, the
// same clip on two tracks. Both would land on one session sitting at the
// other's timestamp, so every frame seeked backwards and re-decoded from a
// keyframe, twice. An overlay from the same file made a ten second export take
// 79 seconds against 3 seconds for the identical overlay from a second file.
Error acquireDecoder(const std::string& path, double seconds,
                     DecoderSession** out) {
  auto& cache = decoderCache();
  auto best = cache.end();
  size_t samePath = 0;
  for (auto it = cache.begin(); it != cache.end(); ++it) {
    if ((*it)->path != path) continue;
    ++samePath;
    // A still has one frame and is never seeked, so any session on it serves
    // every request equally.
    if ((*it)->still) {
      best = it;
      break;
    }
    if (!canReachForward(it->get(), seconds)) continue;
    // The closest one behind the request decodes the fewest frames to get
    // there.
    if (best == cache.end() || (*it)->heldPtsSec > (*best)->heldPtsSec) {
      best = it;
    }
  }
  if (best == cache.end() && samePath > 0 && samePath >= kMaxSessionsPerPath) {
    // Already reading this file from as many places as allowed: take the least
    // recently used of them and let it seek.
    for (auto it = cache.begin(); it != cache.end(); ++it) {
      if ((*it)->path == path) best = it;
    }
  }
  if (best != cache.end()) {
    cache.splice(cache.begin(), cache, best);  // most recently used
    *out = cache.front().get();
    return Error::None;
  }

  auto session = std::make_unique<DecoderSession>();
  session->path = path;
  const Error err = openVideoDecoder(path, session.get());
  if (err != Error::None) return err;
  cache.push_front(std::move(session));
  while (cache.size() > kMaxCachedDecoders) cache.pop_back();
  *out = cache.front().get();
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

// Pulls frames until one covers [seconds]. Never seeks; the caller decides
// when a seek is needed. Leaves the result in s->held.
Error decodeForwardTo(DecoderSession* s, double seconds, double epsilon) {
  AVPacket* pkt = av_packet_alloc();
  if (!s->held) s->held = av_frame_alloc();
  if (!s->scratch) s->scratch = av_frame_alloc();
  const AVRational tb = s->stream->time_base;
  int decoded = 0;
  bool flushed = false;

  while (true) {
    int ret = 0;
    // Decode into scratch, then hand ownership to held: a failed receive must
    // not blank the frame we would otherwise fall back on.
    while ((ret = avcodec_receive_frame(s->codec, s->scratch)) == 0) {
      av_frame_unref(s->held);
      av_frame_move_ref(s->held, s->scratch);
      ++decoded;
      s->heldValid = true;
      s->heldPtsSec = s->held->pts != AV_NOPTS_VALUE
                          ? static_cast<double>(s->held->pts) * av_q2d(tb)
                          : -1.0;
      if (s->heldPtsSec < 0 || s->heldPtsSec >= seconds - epsilon ||
          decoded > 600) {
        av_packet_free(&pkt);
        return Error::None;
      }
    }
    if (ret == AVERROR_EOF) break;

    if (av_read_frame(s->format, pkt) < 0) {
      if (!flushed) {
        avcodec_send_packet(s->codec, nullptr);  // drain
        flushed = true;
        continue;
      }
      break;
    }
    if (pkt->stream_index == s->streamIndex &&
        avcodec_send_packet(s->codec, pkt) < 0) {
      av_packet_unref(pkt);
      av_packet_free(&pkt);
      setLastError("decoder rejected packet");
      return Error::MediaDecodeFailed;
    }
    av_packet_unref(pkt);
  }

  av_packet_free(&pkt);
  // Past the end of the file: the last frame we decoded is the best answer.
  if (s->heldValid && s->held->width > 0) return Error::None;
  s->heldValid = false;
  setLastError("no decodable frame found near requested time");
  return Error::MediaDecodeFailed;
}

// Positions the session on the frame covering [seconds] and returns it as a
// borrowed pointer owned by the session.
Error decodeFrameNear(DecoderSession* s, double seconds, AVFrame** outFrame) {
  const double frameDur = frameDurationOf(s);
  const double epsilon = frameDur * 0.5;

  // Same frame as last time (common while parking on a playhead).
  if (s->heldValid && s->held && s->held->width > 0 && s->heldPtsSec >= 0 &&
      seconds >= s->heldPtsSec - epsilon &&
      seconds < s->heldPtsSec + frameDur - epsilon) {
    *outFrame = s->held;
    return Error::None;
  }

  // Slightly ahead: decoding forward beats a seek + keyframe re-decode, and it
  // is what playback and small scrubs do almost every frame.
  const bool forwardOk = s->heldValid && s->held && s->held->width > 0 &&
                         s->heldPtsSec >= 0 &&
                         seconds > s->heldPtsSec &&
                         seconds - s->heldPtsSec <= 2.0;
  // A still is never seeked: its file holds one packet, and asking the
  // single-image demuxers to seek leaves them unable to read it at all — a
  // JPEG then failed every decode and drew the offline slate instead of the
  // photo. A freshly opened session is already positioned at the only frame
  // there is.
  if (!forwardOk && !s->still) {
    const AVRational tb = s->stream->time_base;
    const int64_t targetTs = static_cast<int64_t>(seconds / av_q2d(tb));
    if (seconds > 0.5) {
      if (avformat_seek_file(s->format, s->streamIndex, INT64_MIN, targetTs,
                             targetTs, 0) < 0) {
        av_seek_frame(s->format, -1, 0, AVSEEK_FLAG_BACKWARD);
      }
    } else {
      av_seek_frame(s->format, -1, 0, AVSEEK_FLAG_BACKWARD);
    }
    avcodec_flush_buffers(s->codec);
    s->heldValid = false;
    s->heldPtsSec = -1.0;
  }

  const Error err = decodeForwardTo(s, seconds, epsilon);
  if (err != Error::None) return err;
  if (!s->held || s->held->width <= 0) {
    s->heldValid = false;
    setLastError("decoder produced an empty frame");
    return Error::MediaDecodeFailed;
  }
  *outFrame = s->held;
  return Error::None;
}

}  // namespace

Error extractFrameRgba(const std::string& path, double seconds, int targetWidth,
                       DecodedFrame* outFrame) {
  if (!outFrame || path.empty()) {
    setLastError("extractFrameRgba: invalid arguments");
    return Error::InvalidArgument;
  }
  seconds = std::max(0.0, seconds);

  DecoderSession* session = nullptr;
  Error err = acquireDecoder(path, seconds, &session);
  if (err != Error::None) return err;

  // A still already scaled for this output size: hand back the cached pixels
  // rather than decoding the source again for a frame that cannot differ.
  if (session->still && !session->stillRgba.empty() &&
      session->stillTargetWidth == targetWidth) {
    outFrame->width = session->stillW;
    outFrame->height = session->stillH;
    outFrame->rgba.assign(session->stillRgba.begin(), session->stillRgba.end());
    return Error::None;
  }

  AVFrame* frame = nullptr;  // borrowed from the session
  // A still has one frame; asking for it at the clip-local time would send the
  // decoder seeking past the end of a one-packet file on every call.
  err = decodeFrameNear(session, session->still ? 0.0 : seconds, &frame);
  if (err != Error::None) return err;

  const int srcW = frame->width;
  const int srcH = frame->height;
  int dstW = targetWidth > 0 ? targetWidth : srcW;
  dstW -= dstW % 2;
  int dstH = static_cast<int>(std::llround(static_cast<double>(srcH) * dstW / srcW));
  dstH -= dstH % 2;
  if (dstW <= 0 || dstH <= 0) {
    setLastError("degenerate output size");
    return Error::InvalidArgument;
  }

  // Deprecated JPEG-range formats are the same layout as their plain variants;
  // naming them explicitly and flagging full range keeps swscale quiet and the
  // levels correct.
  AVPixelFormat srcFmt = static_cast<AVPixelFormat>(frame->format);
  bool fullRange = frame->color_range == AVCOL_RANGE_JPEG;
  switch (srcFmt) {
    case AV_PIX_FMT_YUVJ420P: srcFmt = AV_PIX_FMT_YUV420P; fullRange = true; break;
    case AV_PIX_FMT_YUVJ422P: srcFmt = AV_PIX_FMT_YUV422P; fullRange = true; break;
    case AV_PIX_FMT_YUVJ444P: srcFmt = AV_PIX_FMT_YUV444P; fullRange = true; break;
    case AV_PIX_FMT_YUVJ440P: srcFmt = AV_PIX_FMT_YUV440P; fullRange = true; break;
    default: break;
  }

  // Building a scaler is expensive; keep the one configured for this geometry.
  if (!session->sws || session->swsSrcW != srcW || session->swsSrcH != srcH ||
      session->swsSrcFmt != srcFmt || session->swsDstW != dstW ||
      session->swsDstH != dstH) {
    if (session->sws) sws_freeContext(session->sws);
    // Bicubic pays for itself when shrinking (bilinear visibly softens); on an
    // upscale it costs several ms a frame for no visible gain.
    const int flags = dstW < srcW ? SWS_BICUBIC : SWS_BILINEAR;
    session->sws = sws_getContext(srcW, srcH, srcFmt, dstW, dstH,
                                  AV_PIX_FMT_RGBA, flags, nullptr, nullptr,
                                  nullptr);
    if (!session->sws) {
      setLastError("sws_getContext failed");
      return Error::InternalError;
    }
    session->swsSrcW = srcW;
    session->swsSrcH = srcH;
    session->swsSrcFmt = srcFmt;
    session->swsDstW = dstW;
    session->swsDstH = dstH;

    const int* coeffs = sws_getCoefficients(frame->colorspace == AVCOL_SPC_UNSPECIFIED
                                                ? SWS_CS_ITU709
                                                : frame->colorspace);
    sws_setColorspaceDetails(session->sws, coeffs, fullRange ? 1 : 0,
                             sws_getCoefficients(SWS_CS_DEFAULT), 1, 0, 1 << 16,
                             1 << 16);
  }

  // resize, not assign: sws_scale writes every byte, so pre-zeroing the buffer
  // is a wasted pass over several megabytes each frame.
  outFrame->rgba.resize(static_cast<size_t>(dstW) * dstH * 4);
  uint8_t* dstData[4] = {outFrame->rgba.data(), nullptr, nullptr, nullptr};
  int dstLinesize[4] = {dstW * 4, 0, 0, 0};
  sws_scale(session->sws, frame->data, frame->linesize, 0, srcH, dstData,
            dstLinesize);

  outFrame->width = dstW;
  outFrame->height = dstH;
  rotateRgba(&outFrame->rgba, &outFrame->width, &outFrame->height,
             displayRotationFor(session->stream));
  if (session->still) {
    session->stillRgba = outFrame->rgba;
    session->stillW = outFrame->width;
    session->stillH = outFrame->height;
    session->stillTargetWidth = targetWidth;
  }
  return Error::None;
}

Error extractFrameNative(const std::string& path, double seconds,
                         AVFrame** outFrame, int* outRotation) {
  if (!outFrame || path.empty()) {
    setLastError("extractFrameNative: invalid arguments");
    return Error::InvalidArgument;
  }
  seconds = std::max(0.0, seconds);

  DecoderSession* session = nullptr;
  Error err = acquireDecoder(path, seconds, &session);
  if (err != Error::None) return err;

  AVFrame* frame = nullptr;  // borrowed from the session
  // Same rule as extractFrameRgba: a still holds one frame and must not be
  // seeked.
  err = decodeFrameNear(session, session->still ? 0.0 : seconds, &frame);
  if (err != Error::None) return err;
  if (outRotation) *outRotation = displayRotationFor(session->stream);
  *outFrame = frame;
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
  // YUV420P + explicit JPEG range, rather than the deprecated YUVJ420P alias
  // that makes swscale warn on every thumbnail.
  enc->pix_fmt = AV_PIX_FMT_YUV420P;
  enc->color_range = AVCOL_RANGE_JPEG;
  enc->time_base = AVRational{1, 1};
  av_opt_set_int(enc->priv_data, "qscale", 3, 0);
  if (avcodec_open2(enc, encoder, nullptr) < 0) {
    avcodec_free_context(&enc);
    setLastError("mjpeg encoder open failed");
    return Error::EncodeFailed;
  }

  AVFrame* yuv = av_frame_alloc();
  yuv->format = enc->pix_fmt;
  yuv->color_range = enc->color_range;
  yuv->width = enc->width;
  yuv->height = enc->height;
  av_frame_get_buffer(yuv, 32);

  SwsContext* sws = sws_getContext(frame.width, frame.height, AV_PIX_FMT_RGBA, yuv->width,
                                   yuv->height, enc->pix_fmt, SWS_BILINEAR, nullptr, nullptr,
                                   nullptr);
  sws_setColorspaceDetails(sws, sws_getCoefficients(SWS_CS_DEFAULT), 1,
                           sws_getCoefficients(SWS_CS_DEFAULT), 1, 0, 1 << 16,
                           1 << 16);
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
