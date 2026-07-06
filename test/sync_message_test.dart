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
}
