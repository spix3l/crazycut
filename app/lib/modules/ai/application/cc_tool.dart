part of 'agent.dart';

/// Something the model can run.
///
/// [description] should say *when* to call the tool, not only what it does —
/// models reach for tools conservatively, and a description that reads as a
/// definition rather than a trigger gets under-called.
abstract class CcTool {
  String get name;
  String get description;
  Map<String, dynamic> get schema;

  /// Returns whatever the model should see. Throwing is fine and expected:
  /// the loop converts it into an error result the model can recover from.
  Future<String> run(Map<String, dynamic> args);
}
