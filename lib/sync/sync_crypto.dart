import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// HKDF-SHA256 key derivation + AES-GCM-256 encryption/decryption.
/// Compatible with the C# implementation's scheme.
class SyncCrypto {
  static final _aesGcm = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Derive 32-byte key via HKDF-SHA256.
  /// IKM = "ClipboardManagerSync", salt = "&lt;id1&gt;:&lt;id2&gt;:&lt;pin&gt;" (IDs sorted),
  /// info = "v1-sync-key".
  static Future<SecretKey> deriveKey({
    required String deviceId1,
    required String deviceId2,
    required String pin,
  }) async {
    final ids = [deviceId1, deviceId2]..sort();
    final salt = '${ids[0]}:${ids[1]}:$pin';
    final ikm = utf8.encode('ClipboardManagerSync');
    final saltBytes = utf8.encode(salt);
    final info = utf8.encode('v1-sync-key');

    return await _hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: saltBytes,
      info: info,
    );
  }

  /// Encrypt [plaintext] with [key]. Returns base64(nonce + ciphertext + tag).
  static Future<String> encrypt(String plaintext, SecretKey key) async {
    final nonce = _randomBytes(12);
    final box = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
    );
    final combined = Uint8List(12 + box.cipherText.length + 16);
    combined.setRange(0, 12, nonce);
    combined.setRange(12, 12 + box.cipherText.length, box.cipherText);
    combined.setRange(12 + box.cipherText.length, combined.length, box.mac.bytes);
    return base64.encode(combined);
  }

  /// Decrypt base64(nonce + ciphertext + tag). Returns plaintext.
  static Future<String> decrypt(String b64, SecretKey key) async {
    final combined = base64.decode(b64);
    final nonce = combined.sublist(0, 12);
    final tag = combined.sublist(combined.length - 16);
    final cipherText = combined.sublist(12, combined.length - 16);

    final box = SecretBox(cipherText, nonce: nonce, mac: Mac(tag));
    final plain = await _aesGcm.decrypt(box, secretKey: key);
    return utf8.decode(plain);
  }

  static Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }

  /// Store/load key as base64 string for SharedPreferences.
  static Future<String> keyToBase64(SecretKey key) async {
    final bytes = await key.extractBytes();
    return base64.encode(bytes);
  }

  static SecretKey keyFromBase64(String b64) {
    return SecretKey(base64.decode(b64));
  }
}
