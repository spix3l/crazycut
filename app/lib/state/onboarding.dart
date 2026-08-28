import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:crazycut_app/data/clip_transform.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/data/text_content.dart';
import 'package:crazycut_app/models/rational.dart';

const onboardingSteps = <String>['preview', 'timeline', 'title', 'export'];

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

/// Builds an offline sample from native text clips, so it cannot lose media.
class SampleProjectService {
  static Future<File> create() async {
    final doc = ProjectDoc.empty(
      'CrazyCut Guided Sample',
      width: 1920,
      height: 1080,
      fps: 30,
    );
    doc.extra['onboardingSample'] = true;
    final track = doc.videoTrack()!;
    final cards = <(String, String, String)>[
      ('Cut fast.', '#FF5A5F', 'Press Space to preview.'),
      ('Tell the story.', '#7667F2', 'Select this title and make it yours.'),
      ('Export clean.', '#27AE60', 'Open Export when the edit feels right.'),
    ];
    for (var i = 0; i < cards.length; i++) {
      final card = cards[i];
      doc.clips.add(
        Clip(
          id: generateId(),
          trackId: track.id,
          mediaId: '',
          label: card.$1,
          start: Rt.fromSeconds(i * 4),
          duration: Rt.fromSeconds(4),
          sourceIn: Rt.zero(),
          text: TextContent(
            content: '${card.$1}\n${card.$3}',
            fontSize: 76,
            fontWeight: 'w700',
            lineHeight: 1.35,
            color: '#FFFFFF',
            backgroundColor: card.$2,
            backgroundPadding: 36,
            backgroundRadius: 28,
            shadowBlur: 18,
            shadowOpacity: 0.3,
          ),
          transform: ClipTransform(),
        ),
      );
      doc.markers.add(
        Marker(
          id: generateId(),
          time: Rt.fromSeconds(i * 4),
          name: switch (i) {
            0 => 'Preview',
            1 => 'Edit a title',
            _ => 'Export',
          },
        ),
      );
    }

    var output = await ProjectRepository.projectFile(doc.name);
    var suffix = 2;
    while (output.existsSync()) {
      output = await ProjectRepository.projectFile('${doc.name} $suffix');
      suffix++;
    }
    await ProjectRepository.save(doc, path: output.path);
    return output;
  }
}
