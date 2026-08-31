part of 'onboarding.dart';

/// Durable, local-only progress for the first-edit checklist (UIX-7/8).
class OnboardingState extends ChangeNotifier {
  OnboardingState({Future<Directory> Function()? root})
    : _root = root ?? ProjectRepository.projectsDir;

  static final OnboardingState instance = OnboardingState();
  final Future<Directory> Function() _root;
  final Set<String> _completed = {};
  bool loaded = false;
  bool dismissed = false;

  Set<String> get completed => Set.unmodifiable(_completed);
  bool get finished => onboardingSteps.every(_completed.contains);
  bool isComplete(String id) => _completed.contains(id);

  Future<File> _file() async =>
      File('${(await _root()).path}${Platform.pathSeparator}.onboarding.json');

  Future<void> load() async {
    if (loaded) return;
    try {
      final file = await _file();
      if (file.existsSync()) {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, dynamic>) {
          dismissed = json['dismissed'] == true;
          final steps = json['completed'];
          if (steps is List) {
            _completed.addAll(
              steps.whereType<String>().where(onboardingSteps.contains),
            );
          }
        }
      }
    } on Object {
      // Broken optional state must never stop the editor opening.
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> toggle(String id) async {
    if (!onboardingSteps.contains(id)) return;
    _completed.contains(id) ? _completed.remove(id) : _completed.add(id);
    dismissed = false;
    notifyListeners();
    await _save();
  }

  Future<void> dismiss() async {
    dismissed = true;
    notifyListeners();
    await _save();
  }

  Future<void> showAgain() async {
    dismissed = false;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    await ProjectRepository.writeAtomic(
      await _file(),
      jsonEncode({
        'version': 1,
        'dismissed': dismissed,
        'completed': _completed.toList()..sort(),
      }),
    );
  }
}
