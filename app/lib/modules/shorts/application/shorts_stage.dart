part of 'shorts_flow.dart';

enum ShortsStage {
  /// Nothing has been asked for yet.
  idle,

  /// Waiting on the local speech model.
  transcribing,

  /// Waiting on the model to nominate moments.
  proposing,

  /// Candidates are on screen awaiting accept/reject.
  reviewing,

  /// Finished, cancelled, or failed — [error] and [candidates] say which.
  done,
}
