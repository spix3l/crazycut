part of 'ai_settings.dart';

/// A selectable adapter, described well enough for the settings screen to
/// render it without knowing anything about the adapter itself.
class AiProviderDescriptor {
  const AiProviderDescriptor({
    required this.id,
    required this.name,
    required this.blurb,
    required this.defaultBaseUrl,
    required this.defaultModel,
    required this.needsKey,
    required this.defaults,
  });

  final String id;
  final String name;
  final String blurb;
  final String defaultBaseUrl;
  final String defaultModel;
  final bool needsKey;
  final LlmCapabilities defaults;
}

/// Adding a provider is one entry here plus one file in `providers/` (AI-10).
const List<AiProviderDescriptor> kAiProviders = [
  AiProviderDescriptor(
    id: 'ollama',
    name: 'Ollama (local)',
    blurb:
        'A model running on this machine. No account, no API key, and nothing '
        'leaves your computer.',
    defaultBaseUrl: 'http://127.0.0.1:11434',
    defaultModel: 'llama3.1',
    needsKey: false,
    defaults: OllamaProvider.defaultCapabilities,
  ),
  AiProviderDescriptor(
    id: 'openai-compatible',
    name: 'OpenAI-compatible',
    blurb:
        'Any service speaking the /v1/chat/completions API: OpenAI, '
        'OpenRouter, Groq, Together, LM Studio, vLLM, llama.cpp and others. '
        'Set the base URL to whichever you use.',
    defaultBaseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o',
    needsKey: true,
    defaults: OpenAiCompatibleProvider.defaultCapabilities,
  ),
  AiProviderDescriptor(
    id: 'anthropic',
    name: 'Anthropic',
    blurb: 'Claude models through the Anthropic Messages API.',
    defaultBaseUrl: 'https://api.anthropic.com/v1',
    defaultModel: 'claude-sonnet-4-5',
    needsKey: true,
    defaults: AnthropicProvider.defaultCapabilities,
  ),
];

AiProviderDescriptor? descriptorFor(String id) {
  for (final d in kAiProviders) {
    if (d.id == id) return d;
  }
  return null;
}

/// Everything about the AI configuration except the secret, which lives in the
/// OS keychain (AI-3) and is deliberately absent from this object so it cannot
/// be serialized by accident.
