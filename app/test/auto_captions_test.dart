import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/transcript.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/auto_captions.dart';

void main() {
  test('selected audible clip wins over the longest fallback', () {
    final doc = ProjectDoc.empty('Sources');
    doc.media.addAll([
      MediaAsset(
        id: 'short-media',
        name: 'short.mp4',
        path: '/short.mp4',
        type: 'video',
        duration: Rt.fromSeconds(10),
        hasAudio: true,
      ),
      MediaAsset(
        id: 'long-media',
        name: 'long.mp4',
        path: '/long.mp4',
        type: 'video',
        duration: Rt.fromSeconds(60),
        hasAudio: true,
      ),
    ]);
    final selected = Clip(
      id: 'short',
      trackId: doc.videoTrack()!.id,
      mediaId: 'short-media',
      label: 'short',
      start: Rt.zero(),
      duration: Rt.fromSeconds(10),
      sourceIn: Rt.zero(),
    );
    final longest = Clip(
      id: 'long',
      trackId: doc.videoTrack()!.id,
      mediaId: 'long-media',
      label: 'long',
      start: Rt.fromSeconds(20),
      duration: Rt.fromSeconds(60),
      sourceIn: Rt.zero(),
    );
    doc.clips.addAll([selected, longest]);

    expect(chooseAutoCaptionSource(doc, selected)?.clip.id, 'short');
    expect(chooseAutoCaptionSource(doc, null)?.clip.id, 'long');
  });

  test('trimmed, sped-up transcript maps into sequence time', () {
    final clip = Clip(
      id: 'clip',
      trackId: 'video',
      mediaId: 'media',
      label: 'clip',
      start: Rt.fromSeconds(10),
      duration: Rt.fromSeconds(5),
      sourceIn: Rt.fromSeconds(4),
      speed: '2/1',
    );
    const transcript = Transcript(
      language: 'en',
      durationSeconds: 20,
      segments: [
        TranscriptSegment(start: 2, end: 5, text: 'starts before trim'),
        TranscriptSegment(start: 8, end: 10, text: 'second sentence.'),
        TranscriptSegment(start: 15, end: 18, text: 'fully outside'),
      ],
    );

    final result = captionsForClip(transcript, clip, trackId: 'captions');

    expect(result.track.id, 'captions');
    expect(result.track.items, isNotEmpty);
    expect(result.track.items.first.start.seconds, closeTo(10, 0.001));
    expect(result.track.items.last.end.seconds, lessThanOrEqualTo(15.001));
    expect(
      result.track.items.map((item) => item.text).join(' '),
      isNot(contains('fully outside')),
    );
  });
}
