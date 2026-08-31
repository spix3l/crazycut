part of 'llm_message.dart';

class LlmUsage {
  const LlmUsage({this.inputTokens = 0, this.outputTokens = 0});
  final int inputTokens;
  final int outputTokens;
  int get total => inputTokens + outputTokens;

  LlmUsage operator +(LlmUsage other) => LlmUsage(
    inputTokens: inputTokens + other.inputTokens,
    outputTokens: outputTokens + other.outputTokens,
  );
}
