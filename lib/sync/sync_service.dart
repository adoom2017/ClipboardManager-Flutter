import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import '../core/clipboard_monitor.dart';
import '../models/clipboard_item.dart';
import '../storage/clipboard_store.dart';
import '../storage/settings_store.dart';
import 'sync_connection.dart';
import 'sync_advertiser.dart';
import 'sync_crypto.dart';
import 'sync_discovery.dart';
import 'sync_message.dart';

class PairedPeer {
  final String id;
  final String name;
  final String keyBase64;
  PairedPeer({required this.id, required this.name, required this.keyBase64});

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'keyBase64': keyBase64};

  factory PairedPeer.fromJson(Map<String, dynamic> j) => PairedPeer(
        id: j['id'] as String,
        name: j['name'] as String,
        keyBase64: j['keyBase64'] as String,
      );
}

class SyncService extends ChangeNotifier {
  static final SyncService instance = SyncService._();
  SyncService._();

  ServerSocket? _server;
  final Map<String, SyncConnection> _connections = {};
  final SyncAdvertiser _advertiser = SyncAdvertiser();
  final SyncDiscovery _discovery = SyncDiscovery();
  final List<DiscoveredPeer> _discoveredPeers = [];
  List<DiscoveredPeer> get discoveredPeers => List.unmodifiable(_discoveredPeers);
  StreamSubscription<ClipboardItem>? _clipboardSub;

  // Pairing pending: waiting for user confirmation
  final Map<String, _PendingPairing> _pendingPairings = {};

  // Callback: called when pairing request arrives (show dialog)
  void Function(String peerId, String peerName, String pin)? onPairingRequest;
  // Callback: callback when successfully paired
  void Function(PairedPeer peer)? onPaired;

  List<PairedPeer> get pairedPeers {
    final raw = SettingsStore().syncPairedPeers;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => PairedPeer.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> start() async {
    final settings = SettingsStore();
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _log('TCP server listening on ${_server!.address.address}:${_server!.port}');
    _server!.listen(_onIncomingConnection);
    _setupClipboardSync();
    await _advertiser.start(
      localId: settings.syncLocalDeviceId,
      localName: _deviceName(),
      serverPort: _server!.port,
    );

    await _discovery.start(
      localId: settings.syncLocalDeviceId,
      localName: _deviceName(),
      serverPort: _server!.port,
    );
    _discovery.peers.listen((peer) {
      if (!_discoveredPeers.any((p) => p.id == peer.id)) {
        _discoveredPeers.add(peer);
        notifyListeners();
      }
    });
  }

  Future<void> stop() async {
    await _clipboardSub?.cancel();
    _clipboardSub = null;
    await _advertiser.stop();
    await _discovery.stop();
    for (final conn in _connections.values) {
      await conn.close();
    }
    _connections.clear();
    await _server?.close();
    _server = null;
  }

  // ─── Outgoing: initiate connection ───────────────────────────────────────

  Future<void> connectTo(DiscoveredPeer peer) async {
    final settings = SettingsStore();
    _log('connectTo peerId=${peer.id} host=${peer.host} port=${peer.port}');
    final socket = await Socket.connect(peer.host, peer.port);
    final conn = SyncConnection(socket, peer.id);
    _connections[peer.id] = conn;

    // Check if already paired
    final existing = pairedPeers.where((p) => p.id == peer.id).firstOrNull;

    // Send HELLO
    await conn.send(SyncMessage(
      type: SyncMessageType.hello,
      senderId: settings.syncLocalDeviceId,
      senderName: _deviceName(),
    ));
    _log('sent hello to peerId=${peer.id}');

    if (existing != null) {
      // Already paired - proceed to sync
      _log('peerId=${peer.id} already paired, sending initial sync');
      await _syncItems(conn, SyncCrypto.keyFromBase64(existing.keyBase64));
    } else {
      // Start pairing. The remote side will display a PIN that the local user enters later.
      _pendingPairings[peer.id] = _PendingPairing(
        peerId: peer.id,
        peerName: peer.name,
        initiatedByLocal: true,
      );
      await conn.send(SyncMessage(
        type: SyncMessageType.pairingRequest,
        senderId: settings.syncLocalDeviceId,
        senderName: _deviceName(),
      ));
      _log('sent pairingRequest to peerId=${peer.id}');
    }

    conn.messages.listen((msg) => _handleMessage(msg, conn));
  }

  // ─── Incoming connections ─────────────────────────────────────────────────

  void _onIncomingConnection(Socket socket) {
    _log('incoming TCP connection from ${socket.remoteAddress.address}:${socket.remotePort}');
    final conn = SyncConnection(socket, '');
    conn.messages.listen((msg) => _handleMessage(msg, conn));
  }

  // ─── Message handling ──────────────────────────────────────────────────────

  void _handleMessage(SyncMessage msg, SyncConnection conn) async {
    _log('received type=${msg.type.name} senderID=${msg.senderId} senderName=${msg.senderName}');
    switch (msg.type) {
      case SyncMessageType.hello:
        _connections[msg.senderId] = conn;
        _log('registered connection for senderID=${msg.senderId}');
        break;

      case SyncMessageType.pairingRequest:
        final pin = _generatePin();
        onPairingRequest?.call(msg.senderId, msg.senderName, pin);
        _pendingPairings[msg.senderId] = _PendingPairing(
          peerId: msg.senderId,
          peerName: msg.senderName,
          pin: pin,
          initiatedByLocal: false,
        );
        _log('pairingRequest from ${msg.senderId}, generated PIN=$pin');
        break;

      case SyncMessageType.pairingPin:
        final pending = _pendingPairings[msg.senderId];
        if (pending == null || pending.initiatedByLocal || pending.pin == null) {
          _log('unexpected pairingPin from ${msg.senderId}, rejecting');
          await _sendPairingReject(conn);
          break;
        }

        final pin = _decodePlainPayload(msg.plainPayload);
        if (pin == null || pin != pending.pin) {
          _log('pairingPin mismatch from ${msg.senderId}: received=$pin expected=${pending.pin}');
          await _sendPairingReject(conn);
          break;
        }

        final key = await SyncCrypto.deriveKey(
          deviceId1: SettingsStore().syncLocalDeviceId,
          deviceId2: msg.senderId,
          pin: pin,
        );
        await _savePeer(PairedPeer(
          id: msg.senderId,
          name: msg.senderName,
          keyBase64: await SyncCrypto.keyToBase64(key),
        ));
        _pendingPairings.remove(msg.senderId);

        await conn.send(SyncMessage(
          type: SyncMessageType.pairingAck,
          senderId: SettingsStore().syncLocalDeviceId,
          senderName: _deviceName(),
          plainPayload: _encodePlainPayload(pin),
        ));
        _log('pairing completed as receiver for ${msg.senderId}');
        notifyListeners();

        if (SettingsStore().autoSync) {
          await _syncItems(conn, key);
        }
        break;

      case SyncMessageType.pairingAck:
        final pending = _pendingPairings.remove(msg.senderId);
        final pin = _decodePlainPayload(msg.plainPayload);
        if (pending != null && pending.initiatedByLocal && pending.pin != null && pin == pending.pin) {
          final key = await SyncCrypto.deriveKey(
            deviceId1: SettingsStore().syncLocalDeviceId,
            deviceId2: msg.senderId,
            pin: pin!,
          );
          await _savePeer(PairedPeer(
            id: msg.senderId,
            name: msg.senderName,
            keyBase64: await SyncCrypto.keyToBase64(key),
          ));
          notifyListeners();
          _log('pairing completed as initiator for ${msg.senderId}');
          await _syncItems(conn, key);
        } else {
          _log('ignored pairingAck from ${msg.senderId}; pending=${pending != null} pinMatch=${pending?.pin == pin}');
        }
        break;

      case SyncMessageType.pairingReject:
        _pendingPairings.remove(msg.senderId);
        _log('pairing rejected by ${msg.senderId}');
        await conn.close();
        _connections.remove(msg.senderId);
        break;

      case SyncMessageType.items:
        final encrypted = msg.encryptedPayload;
        if (encrypted == null) break;
        final peer = pairedPeers.where((p) => p.id == msg.senderId).firstOrNull;
        if (peer == null) break;
        final key = SyncCrypto.keyFromBase64(peer.keyBase64);
        try {
          final plain = await SyncCrypto.decrypt(encrypted, key);
          final payload = jsonDecode(plain) as Map<String, dynamic>;
          final list = (payload['items'] as List<dynamic>? ?? const []);
          _log('received ${list.length} synced item(s) from ${msg.senderId}');
          for (final raw in list) {
            final item = _syncItemFromJson(raw as Map<String, dynamic>);
            await ClipboardStore().addItem(item);
          }
        } catch (error) {
          _log('failed to decrypt/apply items from ${msg.senderId}: $error');
        }
        break;

      case SyncMessageType.ping:
        await conn.send(SyncMessage(
          type: SyncMessageType.pong,
          senderId: SettingsStore().syncLocalDeviceId,
          senderName: _deviceName(),
        ));
        break;

      default:
        break;
    }
  }

  // ─── Pairing confirmation (called from UI) ────────────────────────────────

  Future<void> confirmPairing(String peerId) async {
    // Incoming pairing is completed automatically after the initiator submits the shown PIN.
    notifyListeners();
  }

  Future<void> rejectPairing(String peerId) async {
    final conn = _connections[peerId];
    _pendingPairings.remove(peerId);
    await _sendPairingReject(conn);
    await conn?.close();
    _connections.remove(peerId);
  }

  Future<void> submitPairingPin(String peerId, String pin) async {
    final pending = _pendingPairings[peerId];
    final conn = _connections[peerId];
    if (pending == null || conn == null || !pending.initiatedByLocal) return;

    pending.pin = pin;
    _log('submitting pairingPin to $peerId value=$pin');
    await conn.send(SyncMessage(
      type: SyncMessageType.pairingPin,
      senderId: SettingsStore().syncLocalDeviceId,
      senderName: _deviceName(),
      plainPayload: _encodePlainPayload(pin),
    ));
  }

  Future<void> manualSync() async {
    for (final peer in pairedPeers) {
      final conn = _connections[peer.id];
      if (conn != null && conn.isConnected) {
        final key = SyncCrypto.keyFromBase64(peer.keyBase64);
        await _syncItems(conn, key);
      }
    }
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  Future<void> _syncItems(SyncConnection conn, SecretKey key) async {
    final textItems = ClipboardStore()
        .items
        .where((i) => i.contentType == ClipboardContentType.text)
        .toList();
    final payload = jsonEncode({
      'items': textItems.map((i) => _syncItemToJson(i)).toList(),
    });
    final encrypted = await SyncCrypto.encrypt(payload, key);
    _log('sending full sync with ${textItems.length} item(s)');
    await conn.send(SyncMessage(
      type: SyncMessageType.items,
      senderId: SettingsStore().syncLocalDeviceId,
      senderName: _deviceName(),
      encryptedPayload: encrypted,
    ));
  }

  Future<void> _savePeer(PairedPeer peer) async {
    final peers = pairedPeers;
    peers.removeWhere((p) => p.id == peer.id);
    peers.add(peer);
    await SettingsStore().setSyncPairedPeers(
      jsonEncode(peers.map((p) => p.toJson()).toList()),
    );
    onPaired?.call(peer);
  }

  String _generatePin() {
    final rng = DateTime.now().millisecondsSinceEpoch % 1000000;
    return rng.toString().padLeft(6, '0');
  }

  String _deviceName() {
    return Platform.localHostname;
  }

  void _setupClipboardSync() {
    _clipboardSub?.cancel();
    _clipboardSub = ClipboardMonitor.instance.newItems.listen((item) async {
      if (!SettingsStore().autoSync || item.contentType != ClipboardContentType.text) return;
      for (final peer in pairedPeers) {
        final conn = _connections[peer.id];
        if (conn == null || !conn.isConnected) continue;
        await _syncSingleItem(conn, SyncCrypto.keyFromBase64(peer.keyBase64), item);
      }
    });
  }

  Future<void> _syncSingleItem(SyncConnection conn, SecretKey key, ClipboardItem item) async {
    final payload = jsonEncode({
      'items': [_syncItemToJson(item)],
    });
    final encrypted = await SyncCrypto.encrypt(payload, key);
    _log('auto-syncing single item id=${item.id}');
    await conn.send(SyncMessage(
      type: SyncMessageType.items,
      senderId: SettingsStore().syncLocalDeviceId,
      senderName: _deviceName(),
      encryptedPayload: encrypted,
    ));
  }

  Future<void> _sendPairingReject(SyncConnection? conn) async {
    await conn?.send(SyncMessage(
      type: SyncMessageType.pairingReject,
      senderId: SettingsStore().syncLocalDeviceId,
      senderName: _deviceName(),
    ));
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

class _PendingPairing {
  final String peerId;
  final String peerName;
  final bool initiatedByLocal;
  String? pin;
  _PendingPairing({
    required this.peerId,
    required this.peerName,
    required this.initiatedByLocal,
    this.pin,
  });
}

final DateTime _appleReferenceDate = DateTime.utc(2001, 1, 1);
