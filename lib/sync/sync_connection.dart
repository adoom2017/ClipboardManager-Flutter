import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../core/app_logger.dart';
import 'sync_message.dart';

typedef MessageHandler = void Function(SyncMessage msg);

/// Wraps a TCP socket with 4-byte big-endian length framing.
class SyncConnection {
  /// Exclusive upper bound for a frame body, shared with the macOS client.
  static const int maxBodyLength = 10000000;

  final Socket _socket;
  final String peerId;
  final void Function()? onClosed;
  // Cached because Socket.remoteAddress throws once the socket is destroyed.
  late final String _remote;
  bool _closed = false;

  final StreamController<SyncMessage> _msgCtrl = StreamController.broadcast();
  Stream<SyncMessage> get messages => _msgCtrl.stream;

  bool get isConnected => !_closed;

  SyncConnection(this._socket, this.peerId, {this.onClosed}) {
    _remote = '${_socket.remoteAddress.address}:${_socket.remotePort}';
    _logDebug(
      'open local=${_socket.address.address}:${_socket.port} remote=$_remote peerId=$peerId',
    );
    _socket.listen(
      _onData,
      onDone: _onClose,
      onError: (Object error, StackTrace stackTrace) {
        _logWarn('socket error peerId=$peerId error=$error');
        _onClose();
      },
    );
  }

  final BytesBuilder _pending = BytesBuilder(copy: false);
  int? _frameLength;

  void _onData(Uint8List data) {
    _pending.add(data);
    while (!_closed) {
      final frameLength = _frameLength ?? _readHeader();
      if (frameLength == null || _pending.length < frameLength) return;

      final bytes = _pending.takeBytes();
      _frameLength = null;
      if (bytes.length > frameLength) {
        _pending.add(Uint8List.sublistView(bytes, frameLength));
      }
      _dispatch(Uint8List.sublistView(bytes, 0, frameLength));
    }
  }

  /// Consumes the 4-byte header once it is available. Returns null when more
  /// data is needed or the declared length is invalid (connection aborted).
  int? _readHeader() {
    if (_pending.length < 4) return null;
    final bytes = _pending.takeBytes();
    final length = ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.big);
    if (length == 0 || length >= maxBodyLength) {
      _logWarn('reject frame length=$length peerId=$peerId');
      _abort();
      return null;
    }
    if (bytes.length > 4) {
      _pending.add(Uint8List.sublistView(bytes, 4));
    }
    _frameLength = length;
    return length;
  }

  void _dispatch(Uint8List body) {
    try {
      final msg = SyncMessage.decode(utf8.decode(body));
      _logDebug(
        'recv type=${msg.type.name} peerId=$peerId senderId=${msg.senderId}',
      );
      _msgCtrl.add(msg);
    } catch (_) {}
  }

  void _abort() {
    _socket.destroy();
    _onClose();
  }

  void _onClose() {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    _logDebug('close peerId=$peerId remote=$_remote');
    onClosed?.call();
    _msgCtrl.close();
  }

  Future<void> send(SyncMessage msg) async {
    if (_closed) return;
    final bytes = utf8.encode(msg.encode());
    if (bytes.length >= maxBodyLength) {
      throw StateError('同步内容过大（单条上限约 7MB 文本）');
    }
    _logDebug('send type=${msg.type.name} peerId=$peerId');
    final header = ByteData(4)..setUint32(0, bytes.length, Endian.big);
    _socket.add(header.buffer.asUint8List());
    _socket.add(bytes);
    await _socket.flush();
  }

  Future<void> close() async {
    if (_closed) return;
    _logDebug('close() requested peerId=$peerId');
    try {
      await _socket.close();
    } finally {
      _onClose();
    }
  }

  void _logDebug(String message) =>
      AppLogger.instance.debug('SyncConnection', message);
  void _logWarn(String message) =>
      AppLogger.instance.warn('SyncConnection', message);
}
