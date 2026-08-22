#pragma once

#include <map>
#include <memory>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "core/result.h"

namespace cc {

// Realtime monitoring of the sequence audio mix.
//
// The mix thread renders short chunks of mixTimeline() ahead of the playhead
// into a ring buffer that the audio device drains, and the playhead is read
// back from the number of samples the device has actually consumed — the
// sample-count master clock of architecture §6. Video presentation follows
// this clock, which is what keeps a long sequence from drifting.
//
// Every ffmpeg/miniaudio object has one owning thread: the device callback
// only touches the ring, the mix thread only touches the mixer, and control
// calls only post requests.
class SequencePlayer {
 public:
  SequencePlayer();
  ~SequencePlayer();

  SequencePlayer(const SequencePlayer&) = delete;
  SequencePlayer& operator=(const SequencePlayer&) = delete;

  // Installs the document to mix and the asset id → path map. Safe to call
  // while playing; the change takes effect on the next chunk.
  void setDocument(const nlohmann::json& document,
                   const std::map<std::string, std::string>& mediaPaths);

  // Starts (or repositions and continues) monitoring from [positionSec].
  Error start(double positionSec);
  void stop();
  void seek(double positionSec);

  // Playhead in sequence seconds, derived from consumed samples.
  double position() const;
  bool running() const;

  // Shuttle rate. Beyond ±2× monitoring mutes (AUD-15) rather than shipping a
  // pitch-shifted mess; 1.0 restores normal playback.
  void setRate(double rate);

  // Peak levels of what was last sent to the device, for the meters (AUD-10).
  void levels(float* peakL, float* peakR) const;

  // Names of the available output devices, default first (AUD-14).
  static std::vector<std::string> outputDevices();

  // Selects an output device by name; empty picks the system default. Takes
  // effect on the next start().
  void setOutputDevice(const std::string& name);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace cc
