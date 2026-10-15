import 'package:clipboard_manager/sync/sync_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encrypted payload survives wire encoding', () {
    final original = SyncMessage(
      type: SyncMessageType.items,
      senderId: 'sender',
      senderName: 'Windows',
      encryptedPayload: 'base64-ciphertext',
    );

    final decoded = SyncMessage.decode(original.encode());

    expect(decoded.encryptedPayload, 'base64-ciphertext');
    expect(decoded.toJson().containsKey('plainPayload'), isFalse);
  });

  test('error message carries its code', () {
    final decoded = SyncMessage.decode(
      SyncMessage(
        type: SyncMessageType.error,
        senderId: 'receiver',
        senderName: 'Mac',
        errorCode: SyncErrorCode.decryptFailed.name,
      ).encode(),
    );

    expect(decoded.type, SyncMessageType.error);
    expect(SyncErrorCode.parse(decoded.errorCode), SyncErrorCode.decryptFailed);
    expect(SyncErrorCode.parse('somethingNew'), isNull);
  });

  test('unknown message types are rejected instead of treated as ping', () {
    expect(
      () => SyncMessage.decode('{"type":"bogus","senderID":"x"}'),
      throwsFormatException,
    );
  });
}
