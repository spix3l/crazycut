import 'update_fetch_failure.dart';

/// A failed update check. Callers must fail closed: background checks return
/// to idle, manual checks surface one friendly message.
class UpdateFetchException implements Exception {
  const UpdateFetchException(this.failure, [this.detail = '']);

  final UpdateFetchFailure failure;
  final String detail;

  @override
  String toString() => 'UpdateFetchException($failure${
    detail.isEmpty ? '' : ', $detail'
  })';
}
