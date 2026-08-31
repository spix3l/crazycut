part of 'ai_settings.dart';

@immutable
class AiSettingsSaveResult {
  const AiSettingsSaveResult.success() : error = null;
  const AiSettingsSaveResult.failure(this.error);

  final String? error;
  bool get ok => error == null;
}
