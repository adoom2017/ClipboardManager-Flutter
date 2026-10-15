import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipboard_manager/sync/sync_connection.dart';
import 'package:clipboard_manager/sync/sync_message.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _frame(SyncMessage message) {
  final body = utf8.encode(message.encode());
  final header = ByteData(4)..setUint32(0, body.length, Endian.big);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...body]);
}

void main() {
  late ServerSocket server;
  late Socket client;
  late SyncConnection connection;
  late Completer<void> closed;

  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;
    client = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    closed = Completer<void>();
    connection = SyncConnection(
      await accepted,
      'peer',
      onClosed: closed.complete,
    );
  });

  tearDown(() async {
    client.destroy();
    await server.close();
  });

  test('reassembles frames split and merged across TCP chunks', () async {
    final received = connection.messages.take(2).toList();
    final bytes = [
      ..._frame(
        SyncMessage(
          type: SyncMessageType.hello,
          senderId: 'a',
          senderName: 'A',
        ),
      ),
      ..._frame(
        SyncMessage(type: SyncMessageType.ping, senderId: 'a', senderName: 'A'),
      ),
    ];

    // Split inside the first header, then deliver the rest in one chunk.
    client.add(bytes.sublist(0, 2));
    await client.flush();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    client.add(bytes.sublist(2));
    await client.flush();

    final messages = await received.timeout(const Duration(seconds: 2));
    expect(messages.map((m) => m.type), [
      SyncMessageType.hello,
      SyncMessageType.ping,
    ]);
  });

  test('closes the connection when a frame exceeds the size limit', () async {
    final header = ByteData(4)
      ..setUint32(0, SyncConnection.maxBodyLength, Endian.big);
    client.add(header.buffer.asUint8List());
    await client.flush();

    await closed.future.timeout(const Duration(seconds: 2));
    expect(connection.isConnected, isFalse);
  });

  test('refuses to send a frame over the size limit', () async {
    final message = SyncMessage(
      type: SyncMessageType.items,
      senderId: 'a',
      senderName: 'A',
      encryptedPayload: 'x' * SyncConnection.maxBodyLength,
    );

    expect(() => connection.send(message), throwsStateError);
  });
}
