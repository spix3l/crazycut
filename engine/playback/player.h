#pragma once

#include <cstdint>
#include <string>

#include "core/result.h"

namespace cc {

class PlaybackSession {
 public:
  static PlaybackSession* create(const std::string& path, int videoWidth);
  ~PlaybackSession();

  Error start();
  void pause();
  void resume();
  bool isPlaying() const;
  Error seek(double seconds);

  double positionSeconds() const;
  double durationSeconds() const;
  double fps() const;
  bool reachedEnd() const;

  const uint8_t* lockFrame(int* outW, int* outH);
  void unlockFrame();

 private:
  PlaybackSession() = default;
  struct Impl;
  Impl* impl_ = nullptr;
};

}  // namespace cc
