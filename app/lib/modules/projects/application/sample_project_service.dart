part of 'onboarding.dart';

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
