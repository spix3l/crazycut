part of 'llm_message.dart';

/// How hard the model should think.
///
/// Deliberately an intent rather than a token count: providers express thinking
/// depth in mutually incompatible ways (token budgets, effort levels, a boolean,
/// or not at all). Each adapter maps the intent onto its own wire format and the
/// core stays out of it (AI-6).
enum LlmReasoning { none, auto, deep }
