import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Minimal secret-store contract used by AI settings. Keeping this boundary
/// explicit lets tests prove persistence failures without touching a real
/// keychain.
abstract interface class SecretStore {
  String? get lastSecretError;
  Future<bool> storeSecret(String account, String secret);
  Future<String?> readSecret(String account);
  Future<void> deleteSecret(String account);
}

/// Talks to the host app about things only the OS can do: telling it exports
/// are in flight so quitting asks first (EXP-12), keeping the machine awake
/// mid-render, and holding secrets in the OS keychain (AI-3).
class SystemBridge implements SecretStore {
  SystemBridge._();

  static final SystemBridge instance = SystemBridge._();

  static const MethodChannel _channel = MethodChannel('dev.crazycut/system');

  /// Called by the host when the user chose "cancel exports and quit".
  VoidCallback? onCancelExports;

  bool _installed = false;
  String? _lastSecretError;

  @override
  String? get lastSecretError => _lastSecretError;

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
  @override
  Future<bool> storeSecret(String account, String secret) async {
    _install();
    _lastSecretError = null;
    try {
      final ok = await _channel.invokeMethod<bool>('storeSecret', {
        'account': account,
        'secret': secret,
      });
      if (ok == true) return true;
      _lastSecretError = 'macOS did not accept the keychain item.';
      return false;
    } on MissingPluginException {
      _lastSecretError =
          'The macOS keychain bridge is unavailable. Restart CrazyCut after rebuilding.';
      return false;
    } on PlatformException catch (e) {
      _lastSecretError = e.message ?? 'macOS rejected the keychain item.';
      debugPrint('keychain write failed (${e.code}): $_lastSecretError');
      return false;
    } catch (e) {
      _lastSecretError = 'The system keychain returned an unexpected error.';
      debugPrint('keychain write failed: $e');
      return false;
    }
  }

  /// Reads a secret back, or null when there is none (or no keychain here).
  @override
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

  @override
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
