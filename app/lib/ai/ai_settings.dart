/// Provider registry and configuration (AI-1 … AI-4, AI-8).
///
/// One place decides which adapter is live, what it points at, and whether AI
/// is configured at all. Everything above this file talks to `LlmProvider` and
/// never learns which adapter it got.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:crazycut_app/ai/core/llm_provider.dart';
import 'package:crazycut_app/ai/providers/anthropic_provider.dart';
import 'package:crazycut_app/ai/providers/ollama_provider.dart';
import 'package:crazycut_app/ai/providers/openai_compatible_provider.dart';
import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/state/system_bridge.dart';

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
        'Any service speaking the /v1/chat/completions API — OpenAI, '
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
@immutable
class AiConfig {
  const AiConfig({
    required this.providerId,
    required this.baseUrl,
    required this.model,
    this.speechModelId = 'base.en',
    this.capabilityOverrides = const {},
  });

  final String providerId;
  final String baseUrl;
  final String model;

  /// Which local speech model transcription uses. Lives here so the settings
  /// screen and the transcription service cannot hold two ideas of it.
  final String speechModelId;

  /// User corrections to the adapter's declared capabilities. The same adapter
  /// serves very different backends — an OpenAI-compatible URL may be a hosted
  /// frontier model or a 3B model on a laptop — so the declaration is a default
  /// the user can fix rather than a promise (AI-8).
  final Map<String, bool> capabilityOverrides;

  Map<String, dynamic> toJson() => {
    'providerId': providerId,
    'baseUrl': baseUrl,
    'model': model,
    'speechModelId': speechModelId,
    if (capabilityOverrides.isNotEmpty)
      'capabilityOverrides': capabilityOverrides,
  };

  static AiConfig? fromJson(Map<String, dynamic> json) {
    final providerId = json['providerId'];
    final model = json['model'];
    if (providerId is! String || model is! String) return null;
    final descriptor = descriptorFor(providerId);
    if (descriptor == null) return null;
    return AiConfig(
      providerId: providerId,
      baseUrl: json['baseUrl'] as String? ?? descriptor.defaultBaseUrl,
      model: model,
      speechModelId: json['speechModelId'] as String? ?? 'base.en',
      capabilityOverrides:
          (json['capabilityOverrides'] as Map?)?.map(
            (k, v) => MapEntry(k as String, v == true),
          ) ??
          const {},
    );
  }

  AiConfig copyWith({
    String? providerId,
    String? baseUrl,
    String? model,
    String? speechModelId,
    Map<String, bool>? capabilityOverrides,
  }) => AiConfig(
    providerId: providerId ?? this.providerId,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    speechModelId: speechModelId ?? this.speechModelId,
    capabilityOverrides: capabilityOverrides ?? this.capabilityOverrides,
  );
}

/// Holds the live configuration and hands out providers.
class AiSettings extends ChangeNotifier {
  AiSettings({SystemBridge? bridge, this.storageDirOverride})
    : _bridge = bridge ?? SystemBridge.instance;

  static final AiSettings instance = AiSettings();

  final SystemBridge _bridge;
  final Directory? storageDirOverride;

  AiConfig? _config;
  String? _key;
  bool _loaded = false;

  AiConfig? get config => _config;
  bool get loaded => _loaded;

  /// The chosen speech model, independent of whether a provider is set up:
  /// transcription is local and needs neither an endpoint nor a key (AI-18).
  String get speechModelId => _config?.speechModelId ?? 'base.en';

  /// AI is off until configured (AI-1): with this false, no AI affordance is
  /// shown anywhere and no request is ever made.
  bool get configured {
    final c = _config;
    if (c == null) return false;
    final descriptor = descriptorFor(c.providerId);
    if (descriptor == null) return false;
    if (descriptor.needsKey && (_key == null || _key!.isEmpty)) return false;
    return c.model.isNotEmpty && c.baseUrl.isNotEmpty;
  }

  /// True when a key is stored, without revealing it — the settings screen
  /// shows a placeholder rather than reading the secret back into a field.
  bool get hasKey => _key != null && _key!.isNotEmpty;

  Future<Directory> _dir() async {
    if (storageDirOverride != null) return storageDirOverride!;
    try {
      return await ProjectRepository.projectsDir();
    } catch (_) {
      return await getApplicationSupportDirectory();
    }
  }

  Future<File> _configFile() async =>
      File('${(await _dir()).path}${Platform.pathSeparator}.ai.json');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _configFile();
      if (file.existsSync()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) {
          _config = AiConfig.fromJson(decoded);
        }
      }
    } catch (_) {
      // A broken config is the same as no config: AI stays off rather than
      // blocking startup.
      _config = null;
    }
    final c = _config;
    if (c != null && (descriptorFor(c.providerId)?.needsKey ?? false)) {
      _key = await _bridge.readSecret(_keyAccount(c.providerId));
    }
    notifyListeners();
  }

  String _keyAccount(String providerId) => 'llm.$providerId';

  /// Saves configuration, and the key when one was entered. Passing null for
  /// [apiKey] leaves any stored key alone; passing an empty string clears it.
  Future<void> save(AiConfig config, {String? apiKey}) async {
    _config = config;
    try {
      final file = await _configFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(config.toJson()));
    } catch (e) {
      debugPrint('could not write AI config: $e');
    }

    if (apiKey != null) {
      final account = _keyAccount(config.providerId);
      if (apiKey.isEmpty) {
        await _bridge.deleteSecret(account);
        _key = null;
      } else {
        await _bridge.storeSecret(account, apiKey);
        _key = apiKey;
      }
    } else if (descriptorFor(config.providerId)?.needsKey ?? false) {
      _key = await _bridge.readSecret(_keyAccount(config.providerId));
    }
    notifyListeners();
  }

  Future<void> clear() async {
    final c = _config;
    if (c != null) await _bridge.deleteSecret(_keyAccount(c.providerId));
    _config = null;
    _key = null;
    try {
      final file = await _configFile();
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // Nothing stored, nothing to remove.
    }
    notifyListeners();
  }

  /// Builds a provider for the live configuration, or null when AI is off.
  ///
  /// Callers own the result and should `dispose()` it when done, so a cancelled
  /// request does not leave a socket open.
  LlmProvider? createProvider() {
    final c = _config;
    if (c == null || !configured) return null;
    return buildProvider(c, _key);
  }

  /// Pure factory, exposed so the settings screen can test a configuration
  /// before committing it.
  static LlmProvider? buildProvider(AiConfig config, String? apiKey) {
    final descriptor = descriptorFor(config.providerId);
    if (descriptor == null) return null;
    final caps = _applyOverrides(descriptor.defaults, config.capabilityOverrides);

    switch (config.providerId) {
      case 'ollama':
        return OllamaProvider(
          model: config.model,
          baseUrl: config.baseUrl,
          capabilities: caps,
        );
      case 'openai-compatible':
        return OpenAiCompatibleProvider(
          baseUrl: config.baseUrl,
          model: config.model,
          apiKey: apiKey,
          capabilities: caps,
        );
      case 'anthropic':
        return AnthropicProvider(
          model: config.model,
          apiKey: apiKey ?? '',
          baseUrl: config.baseUrl,
          capabilities: caps,
        );
      default:
        return null;
    }
  }

  static LlmCapabilities _applyOverrides(
    LlmCapabilities base,
    Map<String, bool> overrides,
  ) {
    if (overrides.isEmpty) return base;
    return LlmCapabilities(
      tools: overrides['tools'] ?? base.tools,
      jsonSchema: overrides['jsonSchema'] ?? base.jsonSchema,
      streaming: overrides['streaming'] ?? base.streaming,
      contextWindow: base.contextWindow,
    );
  }
}
