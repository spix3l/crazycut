// Detached Ed25519 verification for the update manifest.
//
// The CI signs the exact bytes of `latest.json` with the offline primary
// key and uploads the base64 signature as `latest.json.sig`. This verifier
// tries every embedded public key from `update_keys.dart` and accepts on
// the first success. Empty key map, malformed signatures, and any thrown
// error all mean "invalid": the caller must treat the manifest as
// untrustworthy and stop (fail closed).

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../domain/update_keys.dart';

class UpdateSignature {
  const UpdateSignature._();

  static const int signatureLength = 64;
  static const int publicKeyLength = 32;

  /// Verifies [message] (the raw `latest.json` bytes) against a base64
  /// detached signature. Never throws.
  static Future<bool> verify({
    required Uint8List message,
    required String signatureBase64,
    Map<String, String>? keys,
  }) async {
    final signatureBytes = _decodeBase64(signatureBase64.trim());
    if (signatureBytes == null || signatureBytes.length != signatureLength) {
      return false;
    }
    final verifyKeys = keys ?? kUpdateVerifyKeys;
    if (verifyKeys.isEmpty) return false;
    final algorithm = Ed25519();
    for (final entry in verifyKeys.values) {
      final publicBytes = _decodeBase64(entry.trim());
      if (publicBytes == null || publicBytes.length != publicKeyLength) {
        continue;
      }
      try {
        final publicKey = SimplePublicKey(
          publicBytes,
          type: KeyPairType.ed25519,
        );
        final signature = Signature(signatureBytes, publicKey: publicKey);
        if (await algorithm.verify(message, signature: signature)) {
          return true;
        }
      } on Object {
        continue;
      }
    }
    return false;
  }

  static Uint8List? _decodeBase64(String input) {
    if (input.isEmpty) return null;
    try {
      return base64.decode(input);
    } on FormatException {
      return null;
    }
  }
}
