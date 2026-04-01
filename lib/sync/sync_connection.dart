import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../core/app_logger.dart';
import 'sync_message.dart';

typedef MessageHandler = void Function(SyncMessage msg);

/// Wraps a TCP socket with 4-byte big-endian length framing.
class SyncConnection {
  final Socket _socket;
  final String peerId;
  final void Function()? onClosed;
  bool _closed = false;

  final StreamController<SyncMessage> _msgCtrl = StreamController.broadcast();
  Stream<SyncMessage> get messages => _msgCtrl.stream;

  bool get isConnected => !_closed;

  SyncConnection(this._socket, this.peerId, {this.onClosed}) {
    _logDebug('open local=${_socket.address.address}:${_socket.port} remote=${_socket.remoteAddress.address}:${_socket.remotePort} peerId=$peerId');
    _socket.listen(
      _onData,
      onDone: _onClose,
      onError: (Object error, StackTrace stackTrace) {
        _logWarn('socket error peerId=$peerId error=$error');
        _onClose();
      },
    );
  }

  final List<int> _buf = [];

  void _onData(List<int> data) {
    _buf.addAll(data);
    while (true) {
      if (_buf.length < 4) break;
      final len = ByteData.sublistView(Uint8List.fromList(_buf.sublist(0, 4)))
          .getUint32(0, Endian.big);
      if (_buf.length < 4 + len) break;
      final msgBytes = _buf.sublist(4, 4 + len);
      _buf.removeRange(0, 4 + len);
      try {
        final msg = SyncMessage.decode(utf8.decode(msgBytes));
        _logDebug('recv type=${msg.type.name} peerId=$peerId senderId=${msg.senderId}');
        _msgCtrl.add(msg);
      } catch (_) {}
    }
  }

  void _onClose() {
    if (_closed) return;
    _closed = true;
    _logDebug('close peerId=$peerId remote=${_socket.remoteAddress.address}:${_socket.remotePort}');
    onClosed?.call();
    _msgCtrl.close();
  }

  Future<void> send(SyncMessage msg) async {
    if (_closed) return;
    _logDebug('send type=${msg.type.name} peerId=$peerId');
    final bytes = utf8.encode(msg.encode());
    final header = ByteData(4)..setUint32(0, bytes.length, Endian.big);
    _socket.add(header.buffer.asUint8List());
    _socket.add(bytes);
    await _socket.flush();
  }

  Future<void> close() async {
    _closed = true;
    _logDebug('close() requested peerId=$peerId');
    await _socket.close();
  }

  void _logDebug(String message) => AppLogger.instance.debug('SyncConnection', message);
  void _logWarn(String message) => AppLogger.instance.warn('SyncConnection', message);
}
