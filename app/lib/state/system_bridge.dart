import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Talks to the host app about things only the OS can do: telling it exports
/// are in flight so quitting asks first (EXP-12) and the machine does not fall
/// asleep mid-render.
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
}
