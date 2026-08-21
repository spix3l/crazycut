import Cocoa
import FlutterMacOS
import CoreVideo
import Darwin

final class NativePlaybackTexture: NSObject, FlutterTexture {
  private weak var registry: FlutterTextureRegistry?
  private(set) var textureId: Int64 = -1

  private var libHandle: UnsafeMutableRawPointer?
  private var session: UnsafeMutableRawPointer?

  private var pixelBuffer: CVPixelBuffer?
  private var bufferWidth = 0
  private var bufferHeight = 0
  private var displayTimer: Timer?

  typealias CreateFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
  typealias DestroyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
  typealias StartFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
  typealias PauseFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
  typealias IsPlayingFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
  typealias SeekFn = @convention(c) (UnsafeMutableRawPointer?, Double) -> Int32
  typealias PositionFn = @convention(c) (UnsafeMutableRawPointer?) -> Double
  typealias DurationFn = @convention(c) (UnsafeMutableRawPointer?) -> Double
  typealias FpsFn = @convention(c) (UnsafeMutableRawPointer?) -> Double
  typealias LockFrameFn = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutablePointer<Int32>?,
    UnsafeMutablePointer<Int32>?
  ) -> UnsafePointer<UInt8>?
  typealias UnlockFrameFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
  typealias ReachedEndFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32

  private var fCreate: CreateFn?
  private var fDestroy: DestroyFn?
  private var fStart: StartFn?
  private var fPause: PauseFn?
  private var fResume: PauseFn?
  private var fIsPlaying: IsPlayingFn?
  private var fSeek: SeekFn?
  private var fPosition: PositionFn?
  private var fDuration: DurationFn?
  private var fFps: FpsFn?
  private var fLockFrame: LockFrameFn?
  private var fUnlockFrame: UnlockFrameFn?
  private var fReachedEnd: ReachedEndFn?

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
  }

  func open(engineLibPath: String, mediaPath: String, result: @escaping FlutterResult) {
    close()

    guard let handle = dlopen(engineLibPath, RTLD_NOW | RTLD_LOCAL) else {
      result(FlutterError(code: "dlopen_failed",
                          message: String(cString: dlerror()),
                          details: nil))
      return
    }
    libHandle = handle

    func sym<T>(_ name: String, as type: T.Type) -> T? {
      guard let p = dlsym(handle, name) else { return nil }
      return unsafeBitCast(p, to: type)
    }

    fCreate = sym("cc_playback_create", as: CreateFn.self)
    fDestroy = sym("cc_playback_destroy", as: DestroyFn.self)
    fStart = sym("cc_playback_start", as: StartFn.self)
    fPause = sym("cc_playback_pause", as: PauseFn.self)
    fResume = sym("cc_playback_resume", as: PauseFn.self)
    fIsPlaying = sym("cc_playback_is_playing", as: IsPlayingFn.self)
    fSeek = sym("cc_playback_seek", as: SeekFn.self)
    fPosition = sym("cc_playback_position", as: PositionFn.self)
    fDuration = sym("cc_playback_duration", as: DurationFn.self)
    fFps = sym("cc_playback_fps", as: FpsFn.self)
    fLockFrame = sym("cc_playback_lock_frame", as: LockFrameFn.self)
    fUnlockFrame = sym("cc_playback_unlock_frame", as: UnlockFrameFn.self)
    fReachedEnd = sym("cc_playback_reached_end", as: ReachedEndFn.self)

    guard fCreate != nil, fDestroy != nil, fStart != nil else {
      result(FlutterError(code: "abi_error",
                          message: "engine missing playback symbols — rebuild engine",
                          details: nil))
      return
    }

    guard let sessionPtr = fCreate?(mediaPath) else {
      result(FlutterError(code: "open_failed",
                          message: "could not open media for playback",
                          details: nil))
      return
    }
    session = sessionPtr

    textureId = registry?.register(self) ?? -1
    if textureId < 0 {
      result(FlutterError(code: "register_failed",
                          message: "texture registration failed",
                          details: nil))
      return
    }
    _ = fStart?(session)

    let fps = min(max(fFps?(session) ?? 30.0, 10), 60)
    let interval = 1.0 / fps
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      self?.presentTick()
    }
    RunLoop.main.add(timer, forMode: .common)
    displayTimer = timer

    result([
      "textureId": textureId,
      "duration": fDuration?(session) ?? 0,
      "fps": fps,
    ])
  }

  private func presentTick() {
    guard let session = session,
          let lock = fLockFrame,
          let unlock = fUnlockFrame,
          let registry = registry else { return }

    var w: Int32 = 0
    var h: Int32 = 0
    guard let pixels = lock(session, &w, &h), w > 0, h > 0 else { return }

    defer { unlock(session) }

    if pixelBuffer == nil || Int(w) != bufferWidth || Int(h) != bufferHeight {
      var newBuffer: CVPixelBuffer?
      let attrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32RGBA,
        kCVPixelBufferWidthKey: Int(w),
        kCVPixelBufferHeightKey: Int(h),
      ]
      guard CVPixelBufferCreate(kCFAllocatorDefault, Int(w), Int(h),
                                kCVPixelFormatType_32RGBA,
                                attrs as CFDictionary, &newBuffer) == kCVReturnSuccess,
            let created = newBuffer else {
        return
      }
      pixelBuffer = created
      bufferWidth = Int(w)
      bufferHeight = Int(h)
    }

    guard let pb = pixelBuffer else { return }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    if let base = CVPixelBufferGetBaseAddress(pb) {
      let dstStride = CVPixelBufferGetBytesPerRow(pb)
      let srcStride = Int(w) * 4
      let dst = base.assumingMemoryBound(to: UInt8.self)
      for row in 0..<Int(h) {
        memcpy(dst + row * dstStride,
               pixels + row * srcStride,
               min(srcStride, dstStride))
      }
    }
    registry.textureFrameAvailable(textureId)
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    guard let pb = pixelBuffer else { return nil }
    return Unmanaged.passRetained(pb)
  }

  func play() {
    guard let session = session else { return }
    if fIsPlaying?(session) == 0 {
      if reachedEnd() {
        _ = fSeek?(session, 0.0)
      }
      fResume?(session)
    } else {
      _ = fStart?(session)
    }
  }

  func pause() {
    guard let session = session else { return }
    fPause?(session)
  }

  func seek(_ seconds: Double) {
    guard let session = session else { return }
    _ = fSeek?(session, seconds)
  }

  func position() -> Double {
    guard let session = session else { return 0 }
    return fPosition?(session) ?? 0
  }

  func duration() -> Double {
    guard let session = session else { return 0 }
    return fDuration?(session) ?? 0
  }

  func reachedEnd() -> Bool {
    guard let session = session, let f = fReachedEnd else { return false }
    return f(session) == 1
  }

  func isPlaying() -> Bool {
    guard let session = session, let f = fIsPlaying else { return false }
    return f(session) == 1
  }

  func close() {
    displayTimer?.invalidate()
    displayTimer = nil
    if let session = session {
      fPause?(session)
      fDestroy?(session)
    }
    session = nil
    if textureId >= 0, let registry = registry {
      registry.unregisterTexture(textureId)
    }
    textureId = -1
    pixelBuffer = nil
    if let handle = libHandle {
      dlclose(handle)
      libHandle = nil
    }
  }

  deinit {
    close()
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  private var playbackTexture: NativePlaybackTexture?
  private var playbackChannel: FlutterMethodChannel?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    setupPlaybackChannel()
  }

  private func setupPlaybackChannel() {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else {
      return
    }
    let registrar = controller.registrar(forPlugin: "CrazyCutNativePlayback")
    playbackTexture = NativePlaybackTexture(registry: registrar.textures)
    let channel = FlutterMethodChannel(
      name: "dev.crazycut/playback",
      binaryMessenger: registrar.messenger)
    playbackChannel = channel

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, let texture = self.playbackTexture else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "open":
        guard let args = call.arguments as? [String: Any],
              let engineLib = args["engineLib"] as? String,
              let mediaPath = args["media"] as? String else {
          result(FlutterError(code: "bad_args", message: "open requires engineLib and media", details: nil))
          return
        }
        texture.open(engineLibPath: engineLib, mediaPath: mediaPath, result: result)
      case "play":
        texture.play()
        result(nil)
      case "pause":
        texture.pause()
        result(nil)
      case "seek":
        let seconds = (call.arguments as? [String: Any])?["seconds"] as? Double ?? 0
        texture.seek(seconds)
        result(nil)
      case "position":
        result(texture.position())
      case "isPlaying":
        result(texture.isPlaying())
      case "dispose":
        texture.close()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
