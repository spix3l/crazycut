part of 'commands.dart';

/// Undo/redo history with a memory budget (TIM-20: unlimited depth, capped
/// around 100 MB, oldest dropped first).
class CommandStack {
  CommandStack({this.memoryBudgetBytes = 100 * 1024 * 1024});

  final int memoryBudgetBytes;
  final List<Command> _undo = [];
  final List<Command> _redo = [];
  int _bytes = 0;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get depth => _undo.length;
  int get bytes => _bytes;

  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;

  /// Pushes an already-applied command. Redo is dropped, per TIM-21.
  void push(Command command) {
    _undo.add(command);
    _bytes += command.sizeBytes;
    _redo.clear();
    while (_bytes > memoryBudgetBytes && _undo.length > 1) {
      _bytes -= _undo.removeAt(0).sizeBytes;
    }
  }

  Command? undo(ProjectDoc doc) {
    if (_undo.isEmpty) return null;
    final command = _undo.removeLast();
    _bytes -= command.sizeBytes;
    command.revert(doc);
    _redo.add(command);
    return command;
  }

  Command? redo(ProjectDoc doc) {
    if (_redo.isEmpty) return null;
    final command = _redo.removeLast();
    command.apply(doc);
    _undo.add(command);
    _bytes += command.sizeBytes;
    return command;
  }

  void clear() {
    _undo.clear();
    _redo.clear();
    _bytes = 0;
  }
}
