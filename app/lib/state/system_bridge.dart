import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Talks to the host app about things only the OS can do: telling it exports
/// are in flight so quitting asks first (EXP-12), keeping the machine awake
/// mid-render, and holding secrets in the OS keychain (AI-3).
class SystemBridge {
  SystemBridge._();

  static final SystemBridge instance = SystemBridge._();

  static const MethodChannel _channel = MethodChannel('dev.crazycut/system');

  /// Called by the host when the user chose "cancel exports and quit".
  VoidCallback? onCancelExports;

  bool _installed = false;

  void _install() {
    if (_installed) return;
    _installed = true;
    try {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'cancelExports') onCancelExports?.call();
        return null;
      });
    } catch (_) {
      // No binding (unit tests, headless tools): the app still exports, it
      // just cannot warn the host about it.
      _installed = false;
    }
  }

  /// Publishes the names of jobs still queued or running.
  Future<void> setActiveExports(List<String> names) async {
    _install();
    if (!_installed) return;
    try {
      await _channel.invokeMethod<void>('setActiveExports', names);
    } on MissingPluginException {
      // Platforms without the channel just lose the quit guard.
    } catch (e) {
      debugPrint('system bridge unavailable: $e');
    }
  }

  /// Writes a secret to the OS keychain (AI-3).
  ///
  /// API keys never touch a project file, preferences, a log, or the
  /// diagnostics bundle — the keychain is the only place they live.
  Future<bool> storeSecret(String account, String secret) async {
    _install();
    try {
      final ok = await _channel.invokeMethod<bool>('storeSecret', {
        'account': account,
        'secret': secret,
      });
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('keychain write failed: $e');
      return false;
    }
  }

  /// Reads a secret back, or null when there is none (or no keychain here).
  Future<String?> readSecret(String account) async {
    _install();
    try {
      return await _channel.invokeMethod<String>('readSecret', {
        'account': account,
      });
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('keychain read failed: $e');
      return null;
    }
  }

  Future<void> deleteSecret(String account) async {
    _install();
    try {
      await _channel.invokeMethod<void>('deleteSecret', {'account': account});
    } on MissingPluginException {
      // Nothing stored, nothing to remove.
    } catch (e) {
      debugPrint('keychain delete failed: $e');
    }
  }
}
