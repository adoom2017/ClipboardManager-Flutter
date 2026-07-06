import 'package:clipboard_manager/sync/sync_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encrypts and decrypts a payload', () async {
    final key = await SyncCrypto.deriveKey(
      deviceId1: 'device-b',
      deviceId2: 'device-a',
      pin: '123456',
    );
    final encrypted = await SyncCrypto.encrypt(
      '跨平台 clipboard',
      key,
      nonceBytes: List<int>.generate(12, (index) => index),
    );

    expect(
      encrypted,
      'AAECAwQFBgcICQoLr/gPlfdYHSW1MBcsXO1weTKZk0eqINLMK94uHAlAjw8lf/g=',
    );
    expect(await SyncCrypto.decrypt(encrypted, key), '跨平台 clipboard');
  });

  test('device order does not change the derived key', () async {
    final first = await SyncCrypto.deriveKey(
      deviceId1: 'a',
      deviceId2: 'b',
      pin: '123456',
    );
    final second = await SyncCrypto.deriveKey(
      deviceId1: 'b',
      deviceId2: 'a',
      pin: '123456',
    );

    expect(await first.extractBytes(), await second.extractBytes());
  });
}
