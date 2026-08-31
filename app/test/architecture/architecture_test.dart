import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _publicDeclaration = RegExp(
  r'^(?:(?:abstract|base|final|interface|sealed)\s+)?'
  r'(?:class|enum|extension|mixin|typedef)\s+[A-Za-z][A-Za-z0-9_]*\b',
  multiLine: true,
);

Iterable<File> _dartFiles(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'));

String _relative(File file, String root) => file.absolute.path.replaceFirst(
  '${Directory(root).absolute.path}${Platform.pathSeparator}',
  '',
);

void main() {
  group('production architecture', () {
    test('legacy public buckets do not return', () {
      for (final path in const [
        'lib/state',
        'lib/data',
        'lib/models',
        'lib/features',
      ]) {
        expect(Directory(path).existsSync(), isFalse, reason: path);
      }

      final staleImports = <String>[];
      for (final file in _dartFiles('lib')) {
        final source = file.readAsStringSync();
        if (RegExp(
          r'package:crazycut_app/(?:state|data|models|features)/',
        ).hasMatch(source)) {
          staleImports.add(_relative(file, 'lib'));
        }
      }
      expect(staleImports, isEmpty);
    });

    test('each handwritten file owns at most one public type', () {
      final offenders = <String>[];
      for (final file in _dartFiles('lib')) {
        final relative = _relative(file, 'lib');
        if (relative.endsWith('.gr.dart') ||
            relative.endsWith('_generated.dart')) {
          continue;
        }
        final count =
            _publicDeclaration.allMatches(file.readAsStringSync()).length;
        if (count > 1) offenders.add('$relative ($count declarations)');
      }
      expect(offenders, isEmpty);
    });

    test('layer imports point inward', () {
      final violations = <String>[];
      for (final file in _dartFiles('lib/modules')) {
        final relative = _relative(file, 'lib');
        final source = file.readAsStringSync();
        if (relative.contains('/domain/') &&
            RegExp(
              r'package:crazycut_app/modules/.*/'
              r'(?:application|infrastructure|presentation)/',
            ).hasMatch(source)) {
          violations.add('$relative imports an outer layer');
        }
        if (relative.contains('/application/') &&
            RegExp(
              r'package:crazycut_app/modules/.*/presentation/',
            ).hasMatch(source)) {
          violations.add('$relative imports presentation');
        }
      }
      expect(violations, isEmpty);
    });

    test('presentation uses injected business services', () {
      final violations = <String>[];
      final singleton = RegExp(r'\b([A-Z][A-Za-z0-9]+)\.instance\b');
      const frameworkGlobals = {
        'FocusManager',
        'HardwareKeyboard',
        'WidgetsBinding',
      };
      for (final file in _dartFiles('lib/modules')) {
        final relative = _relative(file, 'lib');
        if (!relative.contains('/presentation/')) continue;
        for (final match in singleton.allMatches(file.readAsStringSync())) {
          if (!frameworkGlobals.contains(match.group(1))) {
            violations.add('$relative uses ${match.group(0)}');
          }
        }
      }
      expect(violations, isEmpty);
    });

    test('native ABI consumers match the public header', () {
      final header = File('../engine/bindings/crazycut.h').readAsStringSync();
      final bindings =
          File(
            'lib/engine/crazycut_bindings_generated.dart',
          ).readAsStringSync();
      final windowsSmoke =
          File('../tools/smoke-windows.ps1').readAsStringSync();

      final headerVersion = RegExp(
        r'#define CC_ABI_VERSION (\d+)',
      ).firstMatch(header)!.group(1);
      final bindingsVersion = RegExp(
        r'const int CC_ABI_VERSION = (\d+);',
      ).firstMatch(bindings)!.group(1);
      final smokeVersion = RegExp(
        r'\$abi\.Invoke\(\) -ne (\d+)',
      ).firstMatch(windowsSmoke)!.group(1);

      expect(bindingsVersion, headerVersion);
      expect(smokeVersion, headerVersion);
    });
  });

  test('counterpart tests mirror production directories', () {
    final misplaced = <String>[];
    for (final file in _dartFiles('test')) {
      final relative = _relative(file, 'test');
      final segments = relative.split(Platform.pathSeparator);
      if (segments.first == 'flows' ||
          segments.first == 'support' ||
          segments.first == 'architecture') {
        continue;
      }
      final productionDirectory =
          segments.length == 1
              ? Directory('lib')
              : Directory(
                [
                  'lib',
                  ...segments.take(segments.length - 1),
                ].join(Platform.pathSeparator),
              );
      if (!productionDirectory.existsSync()) misplaced.add(relative);
    }
    expect(misplaced, isEmpty);
  });
}
