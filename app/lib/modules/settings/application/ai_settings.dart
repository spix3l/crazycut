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

import 'package:crazycut_app/modules/ai/domain/llm_provider.dart';
import 'package:crazycut_app/modules/ai/infrastructure/anthropic_provider.dart';
import 'package:crazycut_app/modules/ai/infrastructure/ollama_provider.dart';
import 'package:crazycut_app/modules/ai/infrastructure/openai_compatible_provider.dart';
import 'package:crazycut_app/modules/project/infrastructure/repository.dart';
import 'package:crazycut_app/core/platform/system_bridge.dart';

part 'ai_config.dart';
part 'ai_provider_descriptor.dart';
part 'ai_settings_save_result.dart';

/// Holds the live configuration and hands out providers.
class AiSettings extends ChangeNotifier {
  AiSettings({SecretStore? bridge, this.storageDirOverride})
    : _bridge = bridge ?? SystemBridge.instance;

  static final AiSettings instance = AiSettings();

  final SecretStore _bridge;
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
  Future<AiSettingsSaveResult> save(AiConfig config, {String? apiKey}) async {
    try {
      final file = await _configFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(config.toJson()));
    } catch (e) {
      debugPrint('could not write AI config: $e');
      return const AiSettingsSaveResult.failure(
        'CrazyCut could not save the AI configuration.',
      );
    }

    String? nextKey;
    if (apiKey != null) {
      final account = _keyAccount(config.providerId);
      if (apiKey.isEmpty) {
        await _bridge.deleteSecret(account);
      } else {
        final stored = await _bridge.storeSecret(account, apiKey);
        if (!stored) {
          _config = config;
          _key = null;
          notifyListeners();
          return AiSettingsSaveResult.failure(
            _bridge.lastSecretError ??
                'The API key could not be stored in the system keychain.',
          );
        }
        nextKey = apiKey;
      }
    } else if (descriptorFor(config.providerId)?.needsKey ?? false) {
      nextKey = await _bridge.readSecret(_keyAccount(config.providerId));
      if (nextKey == null || nextKey.isEmpty) {
        _config = config;
        _key = null;
        notifyListeners();
        return const AiSettingsSaveResult.failure(
          'Enter an API key before saving this provider.',
        );
      }
    }
    _config = config;
    _key = nextKey;
    notifyListeners();
    return const AiSettingsSaveResult.success();
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

  /// Builds a provider for an edited settings draft. When the provider has not
  /// changed, a credential already loaded from the keychain is reused without
  /// exposing it to the settings screen.
  LlmProvider? createDraftProvider(AiConfig config, {String? apiKey}) {
    final storedKey = config.providerId == _config?.providerId ? _key : null;
    return buildProvider(config, apiKey ?? storedKey);
  }

  /// Pure factory, exposed so the settings screen can test a configuration
  /// before committing it.
  static LlmProvider? buildProvider(AiConfig config, String? apiKey) {
    final descriptor = descriptorFor(config.providerId);
    if (descriptor == null) return null;
    final caps = _applyOverrides(
      descriptor.defaults,
      config.capabilityOverrides,
    );

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
