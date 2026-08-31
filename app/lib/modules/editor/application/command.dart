part of 'commands.dart';

/// A reversible document mutation (TIM-20). Commands own the *data* needed to
/// go back and forth; they never hold references to live entities, so undo
/// survives any number of intervening edits.
abstract class Command {
  String get label;

  void apply(ProjectDoc doc);
  void revert(ProjectDoc doc);

  /// Rough retained size, used by the stack's memory cap.
  int get sizeBytes;
}
