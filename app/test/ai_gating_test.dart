import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/ai/ai_settings.dart';
import 'package:crazycut_app/features/editor/presentation/widgets/editor_toolbar.dart';

Future<void> pumpToolbar(WidgetTester tester, {VoidCallback? onFindShorts}) =>
    tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(1440, 900)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 1440,
              child: EditorToolbar(
                projectName: 'Demo',
                onExport: () {},
                onFindShorts: onFindShorts,
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  group('the AI affordance is gated on configuration (AI-1)', () {
    testWidgets('absent when no provider is set up', (tester) async {
      await pumpToolbar(tester);
      expect(find.byIcon(LucideIcons.sparkles), findsNothing);
    });

    testWidgets('present once one is', (tester) async {
      var tapped = false;
      await pumpToolbar(tester, onFindShorts: () => tapped = true);
      expect(find.byIcon(LucideIcons.sparkles), findsOneWidget);
      await tester.tap(find.byIcon(LucideIcons.sparkles));
      await tester.pump();
      expect(tapped, isTrue);
    });
  });

  group('AiSettings.configured', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('cc-ai-gate'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('false before anything is saved', () async {
      final settings = AiSettings(storageDirOverride: dir);
      await settings.load();
      expect(settings.configured, isFalse);
    });

    test('true after saving a keyless provider', () async {
      final settings = AiSettings(storageDirOverride: dir);
      await settings.save(
        const AiConfig(
          providerId: 'ollama',
          baseUrl: 'http://127.0.0.1:11434',
          model: 'llama3.1',
        ),
      );
      expect(settings.configured, isTrue);
      expect(settings.createProvider(), isNotNull);
    });

    test('a key-requiring provider stays off until a key is given', () async {
      final settings = AiSettings(storageDirOverride: dir);
      const config = AiConfig(
        providerId: 'openai-compatible',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-4o',
      );
      await settings.save(config);
      expect(
        settings.configured,
        isFalse,
        reason: 'no key was supplied and this provider needs one',
      );

      await settings.save(config, apiKey: 'sk-test');
      expect(settings.configured, isTrue);
    });

    test('survives a restart', () async {
      await AiSettings(storageDirOverride: dir).save(
        const AiConfig(
          providerId: 'ollama',
          baseUrl: 'http://127.0.0.1:11434',
          model: 'llama3.1',
          speechModelId: 'tiny.en',
        ),
      );

      final reopened = AiSettings(storageDirOverride: dir);
      await reopened.load();
      expect(reopened.configured, isTrue);
      expect(reopened.config!.model, 'llama3.1');
      expect(reopened.speechModelId, 'tiny.en');
    });
  });
}
