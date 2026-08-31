/// The local speech model: where it lives, and getting it there (AI-19).
///
/// CrazyCut ships without a model. The first time transcription is asked for,
/// the user is told the size and asked; declining leaves the feature
/// unavailable with a clear message rather than a crash, and nothing is ever
/// downloaded silently.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:crazycut_app/modules/media/infrastructure/media_cache.dart';

part 'speech_model_info.dart';
part 'speech_model_store.dart';
