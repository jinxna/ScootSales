import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class SignedEnvelopeException implements Exception {
  const SignedEnvelopeException(this.reason);

  final String reason;

  @override
  String toString() => 'SignedEnvelopeException($reason)';
}

class SignedEnvelope {
  const SignedEnvelope._();

  static const String algorithm = 'Ed25519';
  static const int maxPayloadBytes = 256 * 1024;
  static const Duration clockSkew = Duration(minutes: 5);

  static final Ed25519 _ed25519 = Ed25519();
  static final RegExp _keyId = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');
  static final RegExp _b64url = RegExp(r'^[A-Za-z0-9_-]*$');
  static final RegExp _timestamp = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$',
  );
  static const Set<String> _fields = <String>{
    'alg',
    'keyId',
    'payload',
    'signature',
  };

  static Map<String, Uint8List> parseKeys(String text) {
    final Map<String, Uint8List> keys = <String, Uint8List>{};
    if (text.trim().isEmpty) return keys;
    for (final String raw in text.split(',')) {
      final String part = raw.trim();
      final int split = part.indexOf('=');
      if (split < 0) {
        throw const SignedEnvelopeException('Invalid public key entry.');
      }
      final String keyId = part.substring(0, split);
      if (!_keyId.hasMatch(keyId) || keys.containsKey(keyId)) {
        throw const SignedEnvelopeException('Invalid or repeated key ID.');
      }
      final Uint8List key = _decode(part.substring(split + 1));
      if (key.length != 32) {
        throw const SignedEnvelopeException('A public key is 32 bytes.');
      }
      keys[keyId] = key;
    }
    return keys;
  }

  static Future<Map<String, Object?>> verify(
    Object? envelope, {
    required Map<String, Uint8List> keys,
    required String kind,
    int minVersion = 0,
    DateTime? now,
    bool allowExpired = false,
  }) async {
    if (envelope is! Map ||
        envelope.length != _fields.length ||
        !_fields.every(envelope.containsKey) ||
        !_fields.every((String field) => envelope[field] is String)) {
      throw const SignedEnvelopeException('Not a signed envelope.');
    }
    if (envelope['alg'] != algorithm) {
      throw const SignedEnvelopeException('Unsupported signature algorithm.');
    }
    final Uint8List? publicKey = keys[envelope['keyId'] as String];
    if (publicKey == null) {
      throw const SignedEnvelopeException('Unknown signing key.');
    }
    final String payloadText = envelope['payload'] as String;
    final Uint8List payloadBytes = Uint8List.fromList(utf8.encode(payloadText));
    if (payloadBytes.length > maxPayloadBytes) {
      throw const SignedEnvelopeException('Signed payload is too large.');
    }
    final Uint8List signature = _decode(envelope['signature'] as String);
    if (signature.length != 64) {
      throw const SignedEnvelopeException('Invalid signature length.');
    }
    final bool valid = await _ed25519.verify(
      payloadBytes,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) {
      throw const SignedEnvelopeException('Signature does not match.');
    }

    final Object? payload;
    try {
      payload = jsonDecode(payloadText);
    } on FormatException {
      throw const SignedEnvelopeException('Signed payload is not JSON.');
    }
    if (payload is! Map || payload['kind'] != kind) {
      throw const SignedEnvelopeException('Signed payload has the wrong kind.');
    }
    final Object? version = payload['version'];
    if (version is! int || version < 1) {
      throw const SignedEnvelopeException(
        'Signed payload has an invalid version.',
      );
    }
    if (version < minVersion) {
      throw const SignedEnvelopeException(
        'Signed payload is older than the last version seen.',
      );
    }
    final DateTime moment = (now ?? DateTime.now()).toUtc();
    final DateTime issued = _parseTimestamp(payload['issuedAt']);
    final DateTime expires = _parseTimestamp(payload['expiresAt']);
    if (issued.isAfter(moment.add(clockSkew)) || !expires.isAfter(issued)) {
      throw const SignedEnvelopeException('Signed payload has invalid times.');
    }
    if (!allowExpired && !moment.isBefore(expires)) {
      throw const SignedEnvelopeException('Signed payload has expired.');
    }
    return Map<String, Object?>.from(payload);
  }

  static Uint8List _decode(String text) {
    if (!_b64url.hasMatch(text) || text.length % 4 == 1) {
      throw const SignedEnvelopeException('Invalid base64url text.');
    }
    try {
      return base64Url.decode(text + '=' * ((4 - text.length % 4) % 4));
    } on FormatException {
      throw const SignedEnvelopeException('Invalid base64url text.');
    }
  }

  static DateTime _parseTimestamp(Object? text) {
    if (text is String && _timestamp.hasMatch(text)) {
      final DateTime? parsed = DateTime.tryParse(text);
      if (parsed != null &&
          parsed.toUtc().toIso8601String() == text.replaceFirst('Z', '.000Z')) {
        return parsed.toUtc();
      }
    }
    throw const SignedEnvelopeException('Invalid timestamp.');
  }
}
