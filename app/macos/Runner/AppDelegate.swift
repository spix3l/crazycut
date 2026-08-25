import Cocoa
import Security
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var playbackTexture: NativePlaybackTexture?
  private var playbackChannel: FlutterMethodChannel?

  /// Export jobs the Dart side reports as still running (EXP-12). Kept here so
  /// the quit path can ask before throwing work away.
  private var systemChannel: FlutterMethodChannel?
  private var activeExports: [String] = []
  private var sleepActivity: NSObjectProtocol?

  // MARK: - Application lifecycle

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    configurePlaybackChannel()
    configureSystemChannel()
  }

  // MARK: - Termination and export protection

  /// EXP-12: quitting mid-export asks first, and cancelling cleans up the
  /// partial files before the app goes away.
  override func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    guard !activeExports.isEmpty else { return .terminateNow }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = activeExports.count == 1
      ? "An export is still running"
      : "\(activeExports.count) exports are still running"
    alert.informativeText =
      activeExports.joined(separator: "\n") + "\n\nQuitting cancels them."
    alert.addButton(withTitle: "Cancel exports and quit")
    alert.addButton(withTitle: "Keep exporting")

    guard alert.runModal() == .alertFirstButtonReturn else {
      return .terminateCancel
    }

    systemChannel?.invokeMethod("cancelExports", arguments: nil)
    // Give the Dart side a moment to kill the workers and remove partials.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  // MARK: - System channel

  private func configureSystemChannel() {
    guard let controller = flutterViewController else { return }
    let registrar = controller.registrar(forPlugin: "CrazyCutSystem")
    let channel = FlutterMethodChannel(
      name: "dev.crazycut/system",
      binaryMessenger: registrar.messenger)
    systemChannel = channel

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handleSystemCall(call, result: result)
    }
  }

  private func handleSystemCall(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "setActiveExports":
      activeExports = (call.arguments as? [String]) ?? []
      updateSleepAssertion()
      result(nil)
    case "storeSecret":
      guard let args = call.arguments as? [String: Any],
        let account = args["account"] as? String,
        let secret = args["secret"] as? String
      else {
        result(false)
        return
      }
      result(Keychain.store(account: account, secret: secret))
    case "readSecret":
      guard let args = call.arguments as? [String: Any],
        let account = args["account"] as? String
      else {
        result(nil)
        return
      }
      result(Keychain.read(account: account))
    case "deleteSecret":
      if let args = call.arguments as? [String: Any],
        let account = args["account"] as? String
      {
        Keychain.delete(account: account)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Keychain-backed secret storage for LLM API keys (AI-3).
  ///
  /// Keys must never reach a project file, preferences, a log, or the
  /// diagnostics bundle, so the keychain is the only place they are written.
  private enum Keychain {
    private static let service = "dev.crazycut.ai"

    private static func query(_ account: String) -> [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]
    }

    static func store(account: String, secret: String) -> Bool {
      guard let data = secret.data(using: .utf8) else { return false }
      SecItemDelete(query(account) as CFDictionary)
      var item = query(account)
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func read(account: String) -> String? {
      var item = query(account)
      item[kSecReturnData as String] = true
      item[kSecMatchLimit as String] = kSecMatchLimitOne
      var out: CFTypeRef?
      guard SecItemCopyMatching(item as CFDictionary, &out) == errSecSuccess,
        let data = out as? Data
      else { return nil }
      return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
      SecItemDelete(query(account) as CFDictionary)
    }
  }

  /// Keeps the machine awake while an export runs; a laptop that sleeps
  /// halfway through a render is a lost render.
  private func updateSleepAssertion() {
    if activeExports.isEmpty {
      if let activity = sleepActivity {
        ProcessInfo.processInfo.endActivity(activity)
        sleepActivity = nil
      }
      return
    }
    if sleepActivity == nil {
      sleepActivity = ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled, .userInitiated],
        reason: "Exporting video")
    }
  }

  // MARK: - Playback channel

  private var flutterViewController: FlutterViewController? {
    mainFlutterWindow?.contentViewController as? FlutterViewController
  }

  private func configurePlaybackChannel() {
    guard let controller = flutterViewController else { return }
    let registrar = controller.registrar(forPlugin: "CrazyCutNativePlayback")
    playbackTexture = NativePlaybackTexture(registry: registrar.textures)

    let channel = FlutterMethodChannel(
      name: "dev.crazycut/playback",
      binaryMessenger: registrar.messenger)
    playbackChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handlePlaybackCall(call, result: result)
    }
  }

  private func handlePlaybackCall(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard let texture = playbackTexture else {
      result(FlutterMethodNotImplemented)
      return
    }

    switch call.method {
    case "open":
      openPlayback(texture, with: call, result: result)
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

  private func openPlayback(
    _ texture: NativePlaybackTexture,
    with call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any],
          let engineLib = args["engineLib"] as? String,
          let mediaPath = args["media"] as? String else {
      result(FlutterError(
        code: "bad_args",
        message: "open requires engineLib and media",
        details: nil))
      return
    }
    texture.open(engineLibPath: engineLib, mediaPath: mediaPath, result: result)
  }
}
