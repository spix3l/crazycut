part of 'agent.dart';

/// A tool built from a closure, for the many cases that do not need a class.
class InlineTool extends CcTool {
  InlineTool({
    required this.name,
    required this.description,
    required this.schema,
    required this.handler,
  });

  @override
  final String name;
  @override
  final String description;
  @override
  final Map<String, dynamic> schema;
  final Future<String> Function(Map<String, dynamic>) handler;

  @override
  Future<String> run(Map<String, dynamic> args) => handler(args);
}
