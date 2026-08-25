/// The interface every feature talks to (AI-5).
///
/// Features and the agent loop depend on this file and never on an adapter.
/// Adding, swapping or self-hosting a model is one new file in `providers/`
/// plus a registry entry; nothing above this line changes shape.
library;

import 'dart:async';

import 'package:crazycut_app/ai/core/llm_error.dart';
import 'package:crazycut_app/ai/core/llm_message.dart';

// Re-exported so callers importing the provider interface get the error types
// they are required to handle without a second import.
export 'package:crazycut_app/ai/core/llm_error.dart';

/// What an adapter's backend can actually do (AI-8).
///
/// The core uses these to decide whether a request can go out as written or
/// needs the compatibility path in `schema_fallback.dart`. Adapters must be
/// honest here: claiming a capability that is not there turns a graceful
/// degradation into a runtime failure.
class LlmCapabilities {
  const LlmCapabilities({
    required this.tools,
    required this.jsonSchema,
    required this.streaming,
    this.contextWindow = 128000,
  });

  /// Native function/tool calling.
  final bool tools;

  /// Server-enforced structured output against a JSON Schema.
  final bool jsonSchema;

  final bool streaming;

  /// Total tokens the configured model accepts. Used to refuse oversized
  /// requests before spending money on them.
  final int contextWindow;

  static const conservative = LlmCapabilities(
    tools: false,
    jsonSchema: false,
    streaming: false,
    contextWindow: 8192,
  );
}

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

abstract class LlmProvider {
  /// Stable adapter id, e.g. `openai-compatible`, `anthropic`, `ollama`.
  String get id;

  /// Human-readable name for the settings screen.
  String get displayName;

  /// The model this instance is configured for.
  String get model;

  LlmCapabilities get capabilities;

  /// One round-trip. Implementations map failures onto `LlmError` (AI-7).
  Future<LlmResponse> complete(LlmRequest request, {CancellationToken? cancel});

  /// Incremental text. Adapters whose backend cannot stream may fall back to
  /// emitting a single done-delta; callers should check
  /// [LlmCapabilities.streaming] when it matters for UX.
  Stream<LlmDelta> stream(LlmRequest request, {CancellationToken? cancel});

  /// Cheap round-trip used by the settings screen's "Test connection", so a
  /// misconfiguration surfaces before a real task spends tokens (AI-2).
  Future<void> ping({CancellationToken? cancel}) async {
    await complete(
      LlmRequest(
        messages: [LlmMessage.user('Reply with the single word: ok')],
        maxTokens: 16,
        reasoning: LlmReasoning.none,
      ),
      cancel: cancel,
    );
  }

  void dispose() {}
}
