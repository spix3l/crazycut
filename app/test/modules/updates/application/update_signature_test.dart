import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/updates/application/update_signature.dart';
import 'package:crazycut_app/modules/updates/domain/update_keys.dart';

Future<({Map<String, String> keys, String signature, Uint8List message})>
signFixture() async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final message = Uint8List.fromList(utf8.encode('{"tag":"v0.3.0"}'));
  final signature = await algorithm.sign(message, keyPair: keyPair);
  return (
    keys: {'test': base64Encode(publicKey.bytes)},
    signature: base64Encode(signature.bytes),
    message: message,
  );
}

void main() {
  group('UpdateSignature.verify', () {
    test('accepts a valid detached signature', () async {
      final fixture = await signFixture();
      expect(
        await UpdateSignature.verify(
          message: fixture.message,
          signatureBase64: fixture.signature,
          keys: fixture.keys,
        ),
        isTrue,
      );
    });

    test('rejects tampered messages, wrong keys, and malformed input',
        () async {
      final fixture = await signFixture();
      final tampered = Uint8List.fromList(utf8.encode('{"tag":"v9.9.9"}'));
      expect(
        await UpdateSignature.verify(
          message: tampered,
          signatureBase64: fixture.signature,
          keys: fixture.keys,
        ),
        isFalse,
      );

      final other = await Ed25519().newKeyPair();
      final otherPublic = await other.extractPublicKey();
      expect(
        await UpdateSignature.verify(
          message: fixture.message,
          signatureBase64: fixture.signature,
          keys: {'other': base64Encode(otherPublic.bytes)},
        ),
        isFalse,
      );

      expect(
        await UpdateSignature.verify(
          message: fixture.message,
          signatureBase64: fixture.signature,
          keys: const {},
        ),
        isFalse,
      );
      expect(
        await UpdateSignature.verify(
          message: fixture.message,
          signatureBase64: 'not-base64!!',
          keys: fixture.keys,
        ),
        isFalse,
      );
      expect(
        await UpdateSignature.verify(
          message: fixture.message,
          signatureBase64: base64Encode(List.filled(63, 0)),
          keys: fixture.keys,
        ),
        isFalse,
      );
    });

    test('embedded production keys are well formed and distinct', () {
      expect(kUpdateVerifyKeys.length, greaterThanOrEqualTo(2));
      final decoded = [
        for (final value in kUpdateVerifyKeys.values)
          base64Decode(value),
      ];
      for (final key in decoded) {
        expect(key.length, UpdateSignature.publicKeyLength);
      }
      expect(decoded[0], isNot(decoded[1]));
    });
  });
}
