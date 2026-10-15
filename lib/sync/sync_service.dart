import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../core/app_logger.dart';
import '../models/clipboard_item.dart';
import '../storage/clipboard_store.dart';
import '../storage/settings_store.dart';
import 'sync_connection.dart';
import 'sync_advertiser.dart';
import 'sync_discovery.dart';
import 'sync_message.dart';
import 'sync_crypto.dart';

class SyncService extends ChangeNotifier {
  static final SyncService instance = SyncService._();
  SyncService._();
  static const Duration _peerExpiry = Duration(seconds: 45);
  static const Duration _peerCleanupInterval = Duration(seconds: 5);
  static const Duration _syncAckTimeout = Duration(seconds: 3);
  static const Duration _connectTimeout = Duration(seconds: 3);

  ServerSocket? _server;
  final SyncAdvertiser _advertiser = SyncAdvertiser();
  final SyncDiscovery _discovery = SyncDiscovery();
  final List<DiscoveredPeer> _discoveredPeers = [];
  final Map<String, DateTime> _peerLastSeen = {};
  List<DiscoveredPeer> get discoveredPeers =>
      List.unmodifiable(_discoveredPeers);
  StreamSubscription<DiscoveredPeer>? _mdnsPeerSub;
  StreamSubscription<DiscoveredPeer>? _broadcastPeerSub;
  Timer? _peerExpiryTimer;

  Future<void> start() async {
    final settings = SettingsStore();
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _logInfo(
      'TCP server listening on ${_server!.address.address}:${_server!.port}',
    );
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
    _peerExpiryTimer?.cancel();
    _peerExpiryTimer = Timer.periodic(
      _peerCleanupInterval,
      (_) => _pruneExpiredPeers(),
    );
  }

  Future<void> stop() async {
    await _mdnsPeerSub?.cancel();
    _mdnsPeerSub = null;
    await _broadcastPeerSub?.cancel();
    _broadcastPeerSub = null;
    await _advertiser.stop();
    await _discovery.stop();
    _peerExpiryTimer?.cancel();
    _peerExpiryTimer = null;
    _discoveredPeers.clear();
    _peerLastSeen.clear();
    await _server?.close();
    _server = null;
  }

  Future<void> sendItemToPeer(ClipboardItem item, DiscoveredPeer peer) async {
    if (item.contentType != ClipboardContentType.text) return;
    final settings = SettingsStore();
    if (settings.syncPin.length != 6) {
      throw StateError('请先在同步设置中配置 6 位同步 PIN');
    }
    _logInfo(
      'sendItemToPeer itemId=${item.id} peerId=${peer.id} displayName=${peer.displayName} host=${peer.host} port=${peer.port}',
    );
    // Stale peers would otherwise block on the OS TCP timeout (~20s on Windows).
    final socket = await Socket.connect(
      peer.host,
      peer.port,
      timeout: _connectTimeout,
    );
    final ackCompleter = Completer<void>();
    final conn = SyncConnection(
      socket,
      peer.id,
      onClosed: () {
        if (!ackCompleter.isCompleted) {
          ackCompleter.completeError(
            StateError('connection closed before acknowledgment'),
          );
        }
      },
    );
    late final StreamSubscription<SyncMessage> subscription;
    subscription = conn.messages.listen((msg) async {
      if (msg.type == SyncMessageType.error) {
        _logWarn(
          'sync rejected errorCode=${msg.errorCode} peerId=${peer.id} displayName=${peer.displayName}',
        );
        if (!ackCompleter.isCompleted) {
          ackCompleter.completeError(
            StateError(
              SyncErrorCode.parse(
                    msg.errorCode,
                  )?.userMessage(peer.displayName) ??
                  '${peer.displayName} 拒绝了同步内容。',
            ),
          );
        }
        return;
      }
      if (msg.type == SyncMessageType.ack) {
        _logInfo(
          'sync acknowledged peerId=${peer.id} displayName=${peer.displayName}',
        );
        if (!ackCompleter.isCompleted) {
          ackCompleter.complete();
        }
        return;
      }
      await _handleMessage(msg, conn);
    });

    try {
      await conn.send(
        SyncMessage(
          type: SyncMessageType.hello,
          senderId: SettingsStore().syncLocalDeviceId,
          senderName: _deviceName(),
        ),
      );
      await _sendItems(conn, [item], remoteId: peer.id);
      await ackCompleter.future.timeout(_syncAckTimeout);
    } finally {
      // Nobody awaits the completer after a timeout or send error; complete it
      // so the close callback below cannot raise an unhandled async error.
      if (!ackCompleter.isCompleted) ackCompleter.complete();
      await subscription.cancel();
      await conn.close();
    }
  }

  void _onIncomingConnection(Socket socket) {
    _logDebug(
      'incoming TCP connection from ${socket.remoteAddress.address}:${socket.remotePort}',
    );
    final conn = SyncConnection(socket, '');
    conn.messages.listen((msg) => _handleMessage(msg, conn));
  }

  Future<void> _handleMessage(SyncMessage msg, SyncConnection conn) async {
    _logDebug(
      'received type=${msg.type.name} senderID=${msg.senderId} senderName=${msg.senderName}',
    );
    switch (msg.type) {
      case SyncMessageType.hello:
        break;
      case SyncMessageType.items:
        await _receiveItems(msg, conn);
        await conn.close();
        break;
      case SyncMessageType.ping:
        await conn.send(
          SyncMessage(
            type: SyncMessageType.pong,
            senderId: SettingsStore().syncLocalDeviceId,
            senderName: _deviceName(),
          ),
        );
        break;
      case SyncMessageType.ack:
      case SyncMessageType.pong:
      case SyncMessageType.error:
        break;
    }
  }

  Future<void> _receiveItems(SyncMessage msg, SyncConnection conn) async {
    final settings = SettingsStore();
    final encryptedPayload = msg.encryptedPayload;
    if (encryptedPayload == null) {
      _logWarn('reject unencrypted items payload from ${msg.senderId}');
      return _reject(conn, SyncErrorCode.invalidPayload);
    }
    if (settings.syncPin.length != 6) {
      _logWarn(
        'reject items because sync PIN is not configured ${msg.senderId}',
      );
      return _reject(conn, SyncErrorCode.pinNotConfigured);
    }

    final String payloadText;
    try {
      final key = await SyncCrypto.deriveKey(
        deviceId1: settings.syncLocalDeviceId,
        deviceId2: msg.senderId,
        pin: settings.syncPin,
      );
      payloadText = await SyncCrypto.decrypt(encryptedPayload, key);
    } catch (_) {
      _logWarn('failed to decrypt items payload from ${msg.senderId}');
      return _reject(conn, SyncErrorCode.decryptFailed);
    }

    final store = ClipboardStore();
    List<ClipboardItem>? received;
    try {
      final payload = jsonDecode(payloadText) as Map<String, dynamic>;
      received = receivedItems(
        payload['items'] as List<dynamic>? ?? const [],
        exists: store.containsId,
        now: DateTime.now().toUtc(),
      );
    } catch (_) {
      received = null;
    }
    if (received == null) {
      _logWarn('invalid items payload from ${msg.senderId}');
      return _reject(conn, SyncErrorCode.invalidPayload);
    }

    _logInfo('storing ${received.length} synced item(s) from ${msg.senderId}');
    for (final item in received) {
      await store.addItem(item);
    }
    // ACK only after the items are persisted (or already existed).
    await conn.send(
      SyncMessage(
        type: SyncMessageType.ack,
        senderId: settings.syncLocalDeviceId,
        senderName: _deviceName(),
      ),
    );
  }

  Future<void> _reject(SyncConnection conn, SyncErrorCode code) {
    return conn.send(
      SyncMessage(
        type: SyncMessageType.error,
        senderId: SettingsStore().syncLocalDeviceId,
        senderName: _deviceName(),
        errorCode: code.name,
      ),
    );
  }

  static const syncedSourcePrefix = '📡 ';
  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// Converts peer items into local items: de-duplicates by UUID
  /// (case-insensitive), ignores the sender's pin state and stamps items with
  /// the receive time. Returns null when any entry is malformed so the whole
  /// batch is rejected.
  @visibleForTesting
  static List<ClipboardItem>? receivedItems(
    List<dynamic> rawItems, {
    required bool Function(String id) exists,
    required DateTime now,
  }) {
    final seen = <String>{};
    final result = <ClipboardItem>[];
    for (var index = 0; index < rawItems.length; index++) {
      final raw = rawItems[index];
      if (raw is! Map<String, dynamic>) return null;
      final id = raw['id'];
      final content = raw['content'];
      if (id is! String || !_uuidPattern.hasMatch(id) || content is! String) {
        return null;
      }
      final normalizedId = id.toLowerCase();
      if (exists(normalizedId) || !seen.add(normalizedId)) continue;
      final sourceApp = raw['sourceApp'] as String? ?? 'Unknown';
      result.add(
        ClipboardItem(
          id: normalizedId,
          contentType: ClipboardContentType.text,
          content: content,
          // 1ms apart so batch order survives the store's timestamp sort.
          timestamp: now.subtract(Duration(milliseconds: index)),
          sourceApp: sourceApp.startsWith(syncedSourcePrefix)
              ? sourceApp
              : '$syncedSourcePrefix$sourceApp',
        ),
      );
    }
    return result;
  }

  Future<void> _sendItems(
    SyncConnection conn,
    List<ClipboardItem> items, {
    required String remoteId,
  }) async {
    final textItems = items
        .where((item) => item.contentType == ClipboardContentType.text)
        .toList();
    if (textItems.isEmpty) return;
    final payload = jsonEncode({
      'items': textItems.map((item) => _syncItemToJson(item)).toList(),
    });
    _logDebug('sending ${textItems.length} item(s)');
    final settings = SettingsStore();
    final key = await SyncCrypto.deriveKey(
      deviceId1: settings.syncLocalDeviceId,
      deviceId2: remoteId,
      pin: settings.syncPin,
    );
    final encryptedPayload = await SyncCrypto.encrypt(payload, key);
    await conn.send(
      SyncMessage(
        type: SyncMessageType.items,
        senderId: settings.syncLocalDeviceId,
        senderName: _deviceName(),
        encryptedPayload: encryptedPayload,
      ),
    );
  }

  String _deviceName() {
    return Platform.localHostname;
  }

  void _registerDiscoveredPeer(DiscoveredPeer peer) {
    _peerLastSeen[peer.id] = DateTime.now();
    final existingIndex = _discoveredPeers.indexWhere(
      (candidate) => candidate.id == peer.id,
    );
    if (existingIndex >= 0) {
      final previous = _discoveredPeers[existingIndex];
      final mergedDisplayName = _chooseDisplayName(
        previous.displayName,
        peer.displayName,
        peer.id,
      );
      final changed = previous.host != peer.host || previous.port != peer.port;
      final updateMessage =
          'update discovered peer id=${peer.id} displayName=$mergedDisplayName oldHost=${previous.host} oldPort=${previous.port} newHost=${peer.host} newPort=${peer.port}';
      if (changed) {
        _logInfo(updateMessage);
      } else {
        _logDebug(updateMessage);
      }
      _discoveredPeers[existingIndex] = DiscoveredPeer(
        id: peer.id,
        displayName: mergedDisplayName,
        host: peer.host,
        port: peer.port,
      );
    } else {
      _logInfo(
        'add discovered peer id=${peer.id} displayName=${peer.displayName} host=${peer.host} port=${peer.port}',
      );
      _discoveredPeers.add(peer);
    }
    notifyListeners();
  }

  void _pruneExpiredPeers() {
    final cutoff = DateTime.now().subtract(_peerExpiry);
    final expiredIds = _peerLastSeen.entries
        .where((entry) => entry.value.isBefore(cutoff))
        .map((entry) => entry.key)
        .toList();
    if (expiredIds.isEmpty) return;

    for (final peerId in expiredIds) {
      _peerLastSeen.remove(peerId);
      _discoveredPeers.removeWhere((peer) => peer.id == peerId);
      _logInfo('expired stale peer id=$peerId');
    }
    notifyListeners();
  }

  void boostDiscovery() {
    _advertiser.boostDiscovery();
    _discovery.boostDiscovery();
  }

  Map<String, dynamic> _syncItemToJson(ClipboardItem item) => {
    'id': item.id,
    'content': item.content,
    'timestamp':
        item.timestamp.toUtc().difference(_appleReferenceDate).inMilliseconds /
        1000.0,
    'sourceApp': item.sourceApp,
    'isPinned': item.isPinned,
  };

  String _chooseDisplayName(
    String current,
    String incoming,
    String fallbackId,
  ) {
    if (_isBetterDisplayName(current, incoming, fallbackId)) {
      return incoming;
    }
    return current;
  }

  bool _isBetterDisplayName(
    String current,
    String incoming,
    String fallbackId,
  ) {
    final normalizedCurrent = current.trim();
    final normalizedIncoming = incoming.trim();
    if (normalizedCurrent.isEmpty) return normalizedIncoming.isNotEmpty;
    if (normalizedIncoming.isEmpty) return false;
    final currentIsFallback = normalizedCurrent == fallbackId;
    final incomingIsFallback = normalizedIncoming == fallbackId;
    if (currentIsFallback && !incomingIsFallback) return true;
    if (!currentIsFallback && incomingIsFallback) return false;
    return false;
  }

  void _logDebug(String message) =>
      AppLogger.instance.debug('SyncService', message);
  void _logInfo(String message) =>
      AppLogger.instance.info('SyncService', message);
  void _logWarn(String message) =>
      AppLogger.instance.warn('SyncService', message);
}

final DateTime _appleReferenceDate = DateTime.utc(2001, 1, 1);
