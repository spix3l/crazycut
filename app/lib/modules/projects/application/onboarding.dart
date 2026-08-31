import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:crazycut_app/modules/project/domain/clip_transform.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/project/infrastructure/repository.dart';
import 'package:crazycut_app/modules/project/domain/text_content.dart';
import 'package:crazycut_app/core/math/rational.dart';

part 'onboarding_state.dart';
part 'sample_project_service.dart';

const onboardingSteps = <String>['preview', 'timeline', 'title', 'export'];
