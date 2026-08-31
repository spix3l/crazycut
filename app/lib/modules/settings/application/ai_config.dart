part of 'ai_settings.dart';

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
