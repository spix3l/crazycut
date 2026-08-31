part of 'engine.dart';

class EngineException implements Exception {
  EngineException(this.code, this.message);
  final int code;
  final String message;

  @override
  String toString() => 'EngineException($code): $message';
}
