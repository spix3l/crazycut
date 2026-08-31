/// The tool loop (AI-11 … AI-14).
///
/// Written entirely against `LlmProvider`, so it runs unchanged on a frontier
/// hosted model or a small local one. Where the backend has no native tool
/// calling, the text protocol in `core/tool_fallback.dart` fills in and this
/// loop does not notice.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crazycut_app/modules/ai/domain/llm_message.dart';
import 'package:crazycut_app/modules/ai/domain/llm_provider.dart';
import 'package:crazycut_app/modules/ai/domain/tool_fallback.dart';

part 'agent_result.dart';
part 'agent_runner.dart';
part 'agent_turn.dart';
part 'cc_tool.dart';
part 'inline_tool.dart';
