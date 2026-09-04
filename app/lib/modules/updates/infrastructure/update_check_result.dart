import 'dart:typed_data';

import '../domain/update_release.dart';

/// Verified manifest plus the raw bytes it was verified against.
class UpdateCheckResult {
  const UpdateCheckResult({required this.release, required this.manifest});

  final UpdateRelease release;
  final Uint8List manifest;
}
