part of 'dependencies.dart';

/// Process-level composition root.
///
/// Modules receive concrete collaborators from here. This is the only app
/// layer object responsible for choosing production implementations.
class AppDependencies {
  AppDependencies({
    required this.session,
    required this.editor,
    required this.preferences,
    required this.aiSettings,
    required this.sandbox,
    required this.onboarding,
    required this.speechModels,
    required this.exports,
    required this.templates,
    required this.mediaCache,
    required this.posterCache,
    required this.updates,
  });

  factory AppDependencies.production() {
    final preferences = UiPreferences.instance;
    final sandbox = SandboxAccess.instance;
    final editor = EditorDependencies.production();
    final session = AppSession(
      editorDependencies: editor,
      preferences: preferences,
      sandbox: sandbox,
      proxies: ProxyService(),
    );
    return AppDependencies(
      session: session,
      editor: editor,
      preferences: preferences,
      aiSettings: AiSettings.instance,
      sandbox: sandbox,
      onboarding: OnboardingState.instance,
      speechModels: SpeechModelStore.instance,
      exports: ExportService.instance,
      templates: TemplateLibrary.instance,
      mediaCache: MediaCache.instance,
      posterCache: PosterCache.instance,
      updates: UpdateService(preferences: preferences),
    );
  }

  final AppSession session;
  final EditorDependencies editor;
  final UiPreferences preferences;
  final AiSettings aiSettings;
  final SandboxAccess sandbox;
  final OnboardingState onboarding;
  final SpeechModelStore speechModels;
  final ExportService exports;
  final TemplateLibrary templates;
  final MediaCache mediaCache;
  final PosterCache posterCache;
  final UpdateService updates;
}
