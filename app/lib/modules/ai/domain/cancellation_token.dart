part of 'llm_provider.dart';

/// Cooperative cancellation, checked at request boundaries and between agent
/// turns — the same contract the export worker uses (arch §8, AI-13).
class CancellationToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
    _listeners.clear();
  }

  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void throwIfCancelled() {
    if (_cancelled) throw const LlmCancelledError();
  }
}
