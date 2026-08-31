/// The interface every feature talks to (AI-5).
///
/// Features and the agent loop depend on this file and never on an adapter.
/// Adding, swapping or self-hosting a model is one new file in `providers/`
/// plus a registry entry; nothing above this line changes shape.
library;

import 'dart:async';

import 'package:crazycut_app/modules/ai/domain/llm_error.dart';
import 'package:crazycut_app/modules/ai/domain/llm_message.dart';

// Re-exported so callers importing the provider interface get the error types
// they are required to handle without a second import.
export 'package:crazycut_app/modules/ai/domain/llm_error.dart';

part 'cancellation_token.dart';
part 'llm_capabilities.dart';

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
