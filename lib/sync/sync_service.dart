import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/clipboard_item.dart';
import '../storage/clipboard_store.dart';
import '../storage/settings_store.dart';
import 'sync_connection.dart';
import 'sync_advertiser.dart';
import 'sync_discovery.dart';
import 'sync_message.dart';

class SyncService extends ChangeNotifier {
  static final SyncService instance = SyncService._();
  SyncService._();

  ServerSocket? _server;
  final SyncAdvertiser _advertiser = SyncAdvertiser();
  final SyncDiscovery _discovery = SyncDiscovery();
  final List<DiscoveredPeer> _discoveredPeers = [];
  List<DiscoveredPeer> get discoveredPeers => List.unmodifiable(_discoveredPeers);
  StreamSubscription<DiscoveredPeer>? _mdnsPeerSub;
  StreamSubscription<DiscoveredPeer>? _broadcastPeerSub;

  Future<void> start() async {
    final settings = SettingsStore();
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _log('TCP server listening on ${_server!.address.address}:${_server!.port}');
    _server!.listen(_onIncomingConnection);

    await _advertiser.start(
      localId: settings.syncLocalDeviceId,
      localName: _deviceName(),
      serverPort: _server!.port,
    );
    await _mdnsPeerSub?.cancel();
    _mdnsPeerSub = _advertiser.peers.listen(_registerDiscoveredPeer);

    await _discovery.start(
      localId: settings.syncLocalDeviceId,
      localName: _deviceName(),
      serverPort: _server!.port,
    );
    await _broadcastPeerSub?.cancel();
    _broadcastPeerSub = _discovery.peers.listen(_registerDiscoveredPeer);
  }

  Future<void> stop() async {
    await _mdnsPeerSub?.cancel();
    _mdnsPeerSub = null;
    await _broadcastPeerSub?.cancel();
    _broadcastPeerSub = null;
    await _advertiser.stop();
    await _discovery.stop();
    _discoveredPeers.clear();
    await _server?.close();
    _server = null;
  }

  Future<void> sendItemToPeer(ClipboardItem item, DiscoveredPeer peer) async {
    if (item.contentType != ClipboardContentType.text) return;
    _log('sendItemToPeer itemId=${item.id} peerId=${peer.id} host=${peer.host} port=${peer.port}');
    final socket = await Socket.connect(peer.host, peer.port);
    final conn = SyncConnection(socket, peer.id);
    conn.messages.listen((msg) => _handleMessage(msg, conn));

    await conn.send(SyncMessage(
      type: SyncMessageType.hello,
      senderId: SettingsStore().syncLocalDeviceId,
      senderName: _deviceName(),
    ));
    await _sendItems(conn, [item]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await conn.close();
  }

  void _onIncomingConnection(Socket socket) {
    _log('incoming TCP connection from ${socket.remoteAddress.address}:${socket.remotePort}');
    final conn = SyncConnection(socket, '');
    conn.messages.listen((msg) => _handleMessage(msg, conn));
  }

  void _handleMessage(SyncMessage msg, SyncConnection conn) async {
    _log('received type=${msg.type.name} senderID=${msg.senderId} senderName=${msg.senderName}');
    switch (msg.type) {
      case SyncMessageType.hello:
        break;
      case SyncMessageType.items:
        final payloadText = _decodePlainPayload(msg.plainPayload);
        if (payloadText == null) {
          _log('missing items payload from ${msg.senderId}');
          await conn.close();
          break;
        }
        try {
          final payload = jsonDecode(payloadText) as Map<String, dynamic>;
          final list = (payload['items'] as List<dynamic>? ?? const []);
          _log('received ${list.length} synced item(s) from ${msg.senderId}');
          for (final raw in list) {
            final item = _syncItemFromJson(raw as Map<String, dynamic>);
            await ClipboardStore().addItem(item);
          }
        } catch (error) {
          _log('failed to apply items from ${msg.senderId}: $error');
        }
        await conn.close();
        break;
      case SyncMessageType.ping:
        await conn.send(SyncMessage(
          type: SyncMessageType.pong,
          senderId: SettingsStore().syncLocalDeviceId,
          senderName: _deviceName(),
        ));
        break;
      case SyncMessageType.ack:
      case SyncMessageType.pong:
        break;
    }
  }

  Future<void> _sendItems(SyncConnection conn, List<ClipboardItem> items) async {
    final textItems = items.where((item) => item.contentType == ClipboardContentType.text).toList();
    if (textItems.isEmpty) return;
    final payload = jsonEncode({
      'items': textItems.map((item) => _syncItemToJson(item)).toList(),
    });
    _log('sending ${textItems.length} item(s)');
    await conn.send(SyncMessage(
      type: SyncMessageType.items,
      senderId: SettingsStore().syncLocalDeviceId,
      senderName: _deviceName(),
      plainPayload: _encodePlainPayload(payload),
    ));
  }

  String _deviceName() {
    return Platform.localHostname;
  }

  void _registerDiscoveredPeer(DiscoveredPeer peer) {
    final existingIndex = _discoveredPeers.indexWhere((candidate) => candidate.id == peer.id);
    if (existingIndex >= 0) {
      final previous = _discoveredPeers[existingIndex];
      _log(
        'update discovered peer id=${peer.id} '
        'oldHost=${previous.host} oldPort=${previous.port} '
        'newHost=${peer.host} newPort=${peer.port}',
      );
      _discoveredPeers[existingIndex] = peer;
    } else {
      _log('add discovered peer id=${peer.id} host=${peer.host} port=${peer.port}');
      _discoveredPeers.add(peer);
    }
    notifyListeners();
  }

  String _encodePlainPayload(String value) {
    return base64.encode(utf8.encode(value));
  }

  String? _decodePlainPayload(String? value) {
    if (value == null) return null;
    try {
      return utf8.decode(base64.decode(value));
    } catch (_) {
      return value;
    }
  }

  Map<String, dynamic> _syncItemToJson(ClipboardItem item) => {
        'id': item.id,
        'content': item.content,
        'timestamp': item.timestamp.toUtc().difference(_appleReferenceDate).inMilliseconds / 1000.0,
        'sourceApp': item.sourceApp,
        'isPinned': item.isPinned,
      };

  ClipboardItem _syncItemFromJson(Map<String, dynamic> json) {
    final timestamp = json['timestamp'];
    return ClipboardItem(
      id: json['id'] as String,
      contentType: ClipboardContentType.text,
      content: json['content'] as String? ?? '',
      timestamp: _decodeSyncTimestamp(timestamp),
      sourceApp: json['sourceApp'] as String? ?? 'Unknown',
      isPinned: json['isPinned'] as bool? ?? false,
    );
  }

  DateTime _decodeSyncTimestamp(dynamic value) {
    if (value is num) {
      return _appleReferenceDate.add(
        Duration(milliseconds: (value * 1000).round()),
      );
    }
    if (value is String) {
      return DateTime.tryParse(value)?.toUtc() ?? DateTime.now().toUtc();
    }
    return DateTime.now().toUtc();
  }

  void _log(String message) {
    if (kDebugMode) {
      debugPrint('[SyncService] $message');
    }
  }
}

final DateTime _appleReferenceDate = DateTime.utc(2001, 1, 1);
