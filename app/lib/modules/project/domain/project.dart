import 'dart:convert';

import 'package:collection/collection.dart';

import 'package:crazycut_app/modules/project/domain/area_track.dart';
import 'package:crazycut_app/modules/project/domain/caption.dart';
import 'package:crazycut_app/modules/project/domain/clip_transform.dart';
import 'package:crazycut_app/modules/project/domain/param_value.dart';
import 'package:crazycut_app/modules/project/domain/text_content.dart';
import 'package:crazycut_app/modules/project/domain/transition.dart';
import 'package:crazycut_app/core/math/rational.dart';

part 'clip.dart';
part 'fade.dart';
part 'marker.dart';
part 'master_bus.dart';
part 'media_asset.dart';
part 'media_reference.dart';
part 'media_source_kind.dart';
part 'project_doc.dart';
part 'repair_report.dart';
part 'sequence_settings.dart';
part 'thumb_status.dart';
part 'track.dart';
part 'track_height.dart';

const String kSchemaVersion = 'crazycut/project@1';

/// UUIDv7-shaped id: 48-bit millisecond timestamp then randomness, so ids sort
/// in creation order (`02-data-model.md` §3).
String generateId() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final rand = _random;
  String hex(int value, int digits) => (value & ((1 << (digits * 4)) - 1))
      .toRadixString(16)
      .padLeft(digits, '0');
  final a = hex(now >> 16, 8);
  final b = hex(now, 4);
  final c = '7${hex(rand.nextInt(0x1000), 3)}';
  final d = ((8 + rand.nextInt(4)) << 12) | rand.nextInt(0x1000);
  final e =
      '${hex(rand.nextInt(0xFFFFFFFF), 8)}${hex(rand.nextInt(0xFFFF), 4)}';
  return '$a-$b-$c-${hex(d, 4)}-$e';
}

final _random = _XorShift(DateTime.now().microsecondsSinceEpoch);

/// Tiny deterministic PRNG — `dart:math`'s Random would do, but this keeps the
/// id generator dependency-free and seedable in tests.
class _XorShift {
  _XorShift(int seed) : _state = seed == 0 ? 0x2545F4914F6CDD1D : seed;
  int _state;

  int nextInt(int max) {
    _state ^= (_state << 13) & 0xFFFFFFFFFFFFFFF;
    _state ^= _state >> 7;
    _state ^= (_state << 17) & 0xFFFFFFFFFFFFFFF;
    return (_state.abs()) % (max <= 0 ? 1 : max);
  }
}

/// Fields we do not model yet are carried through load → save untouched
/// (`02-data-model.md` §1 "forward-safe").
Map<String, dynamic> _unknown(Map<String, dynamic> json, Set<String> known) => {
  for (final entry in json.entries)
    if (!known.contains(entry.key)) entry.key: entry.value,
};

dynamic _copyJsonValue(dynamic value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): _copyJsonValue(entry.value),
    };
  }
  if (value is List) return [for (final item in value) _copyJsonValue(item)];
  return value;
}

/// Migrates the pre-v1 visual animation payload to the generic clip payload.
/// The old field was image-specific and called the two edges `in`/`out`; the
/// persisted model now names the same behaviors `entry`/`leave` for every
/// visual clip type.
Map<String, dynamic>? _migrateClipAnimation(dynamic value) {
  if (value is! Map) return null;
  final migrated = _copyJsonValue(value) as Map<String, dynamic>;
  if (!migrated.containsKey('entry') && migrated.containsKey('in')) {
    migrated['entry'] = migrated['in'];
  }
  if (!migrated.containsKey('leave') && migrated.containsKey('out')) {
    migrated['leave'] = migrated['out'];
  }
  migrated.remove('in');
  migrated.remove('out');
  return migrated;
}

Map<String, dynamic> _clipExtra(Map<String, dynamic> json) {
  final extra = _unknown(json, {
    'id',
    'trackId',
    'mediaId',
    'label',
    'start',
    'duration',
    'sourceIn',
    'speed',
    'reverse',
    'volume',
    'pan',
    'mute',
    'fadeIn',
    'fadeOut',
    'linkedGroup',
    'effects',
    'blend',
    'transform',
    'text',
  });
  final legacy = extra.remove('imageAnim');
  final current = extra['clipAnim'];
  final animation = _migrateClipAnimation(current ?? legacy);
  if (animation != null) extra['clipAnim'] = animation;
  return extra;
}
