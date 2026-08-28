import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/ai/ai_settings.dart';
import 'package:crazycut_app/ai/providers/openai_compatible_provider.dart';
import 'package:crazycut_app/features/editor/presentation/widgets/editor_toolbar.dart';
import 'package:crazycut_app/state/system_bridge.dart';

class FakeSecretStore implements SecretStore {
  FakeSecretStore({this.failWrites = false});

  final bool failWrites;
  final Map<String, String> values = {};

  @override
  String? get lastSecretError =>
      failWrites ? 'The test keychain rejected the credential.' : null;

  @override
  Future<bool> storeSecret(String account, String secret) async {
    if (failWrites) return false;
    values[account] = secret;
    return true;
  }

  @override
  Future<String?> readSecret(String account) async => values[account];

  @override
  Future<void> deleteSecret(String account) async {
    values.remove(account);
  }
}

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
      final secrets = FakeSecretStore();
      final settings = AiSettings(storageDirOverride: dir, bridge: secrets);
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

      final result = await settings.save(config, apiKey: 'sk-test');
      expect(result.ok, isTrue);
      expect(settings.configured, isTrue);
    });

    test('a failed keychain write is reported and leaves AI off', () async {
      final settings = AiSettings(
        storageDirOverride: dir,
        bridge: FakeSecretStore(failWrites: true),
      );
      final result = await settings.save(
        const AiConfig(
          providerId: 'openai-compatible',
          baseUrl: 'https://api.openai.com/v1',
          model: 'gpt-4o',
        ),
        apiKey: 'sk-test',
      );

      expect(result.ok, isFalse);
      expect(result.error, contains('keychain'));
      expect(settings.configured, isFalse);
    });

    test('a stored key is reused by test-connection drafts', () async {
      final secrets = FakeSecretStore();
      final settings = AiSettings(storageDirOverride: dir, bridge: secrets);
      const config = AiConfig(
        providerId: 'openai-compatible',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-4o',
      );
      await settings.save(config, apiKey: 'sk-persisted');

      final provider = settings.createDraftProvider(config);
      expect(provider, isA<OpenAiCompatibleProvider>());
      expect((provider! as OpenAiCompatibleProvider).apiKey, 'sk-persisted');
      provider.dispose();
    });

    test('a keyed provider survives a restart', () async {
      final secrets = FakeSecretStore();
      const config = AiConfig(
        providerId: 'openai-compatible',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-4o',
      );
      await AiSettings(
        storageDirOverride: dir,
        bridge: secrets,
      ).save(config, apiKey: 'sk-persisted');

      final reopened = AiSettings(storageDirOverride: dir, bridge: secrets);
      await reopened.load();
      expect(reopened.configured, isTrue);
      expect(reopened.hasKey, isTrue);
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
