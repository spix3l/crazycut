import 'dart:convert';

import 'package:collection/collection.dart';

import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/project/domain/transition.dart';
import 'package:crazycut_app/core/math/rational.dart';

part 'clip_template.dart';
part 'slot_kind.dart';
part 'template_edge.dart';
part 'template_lane.dart';
part 'template_media_ref.dart';
part 'template_slot.dart';

/// Schema id of a `.cctemplate` file (`03-features/templates.md` TPL-1).
const String kTemplateSchema = 'crazycut/template@1';

/// File extension of a saved template.
const String kTemplateExtension = 'cctemplate';
