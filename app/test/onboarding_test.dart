import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/state/onboarding.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('cc-onboarding');
    ProjectRepository.rootOverride = root;
  });

  tearDown(() {
    ProjectRepository.rootOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('checklist progress and dismissal survive a new store', () async {
    final state = OnboardingState(root: () async => root);
    await state.load();
    await state.toggle('preview');
    await state.dismiss();

    final restored = OnboardingState(root: () async => root);
    await restored.load();
    expect(restored.isComplete('preview'), isTrue);
    expect(restored.dismissed, isTrue);
  });

  test(
    'sample project is offline-safe and never overwrites a prior one',
    () async {
      final first = await SampleProjectService.create();
      final second = await SampleProjectService.create();

      expect(first.path, isNot(second.path));
      final doc = ProjectRepository.load(first.path);
      expect(doc.extra['onboardingSample'], isTrue);
      expect(doc.media, isEmpty);
      expect(doc.clips, hasLength(3));
      expect(doc.clips.every((clip) => clip.text != null), isTrue);
      expect(doc.sequenceDuration.seconds, 12);
    },
  );
}
