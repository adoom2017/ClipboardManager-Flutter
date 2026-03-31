import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
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
    _server!.listen(_onIncomingConnection);
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

    if (existing != null) {
      // Already paired - proceed to sync
      await _syncItems(conn, SyncCrypto.keyFromBase64(existing.keyBase64));
    } else {
      // Start pairing
      final pin = _generatePin();
      _pendingPairings[peer.id] = _PendingPairing(peerId: peer.id, peerName: peer.name, pin: pin);
      await conn.send(SyncMessage(
        type: SyncMessageType.pairingRequest,
        senderId: settings.syncLocalDeviceId,
        senderName: _deviceName(),
        plainPayload: jsonEncode({'pin': pin}),
      ));
    }

    conn.messages.listen((msg) => _handleMessage(msg, conn));
  }

  // ─── Incoming connections ─────────────────────────────────────────────────

  void _onIncomingConnection(Socket socket) {
    final conn = SyncConnection(socket, '');
    conn.messages.listen((msg) => _handleMessage(msg, conn));
  }

  // ─── Message handling ──────────────────────────────────────────────────────

  void _handleMessage(SyncMessage msg, SyncConnection conn) async {
    switch (msg.type) {
      case SyncMessageType.hello:
        _connections[msg.senderId] = conn;
        break;

      case SyncMessageType.pairingRequest:
        final payload = jsonDecode(msg.plainPayload ?? '{}') as Map<String, dynamic>;
        final pin = payload['pin'] as String? ?? '';
        onPairingRequest?.call(msg.senderId, msg.senderName, pin);
        _pendingPairings[msg.senderId] = _PendingPairing(
          peerId: msg.senderId, peerName: msg.senderName, pin: pin,
        );
        break;

      case SyncMessageType.pairingAck:
        // Receiver confirmed pairing
        final pending = _pendingPairings.remove(msg.senderId);
        if (pending != null) {
          final key = await SyncCrypto.deriveKey(
            deviceId1: SettingsStore().syncLocalDeviceId,
            deviceId2: msg.senderId,
            pin: pending.pin,
          );
          await _savePeer(PairedPeer(
            id: msg.senderId,
            name: msg.senderName,
            keyBase64: await SyncCrypto.keyToBase64(key),
          ));
          notifyListeners();
          await _syncItems(conn, key);
        }
        break;

      case SyncMessageType.pairingReject:
        _pendingPairings.remove(msg.senderId);
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
          final list = jsonDecode(plain) as List<dynamic>;
          for (final raw in list) {
            final item = ClipboardItem.fromJson(raw as Map<String, dynamic>);
            await ClipboardStore().addItem(item);
          }
        } catch (_) {}
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
    final pending = _pendingPairings[peerId];
    final conn = _connections[peerId];
    if (pending == null || conn == null) return;

    final key = await SyncCrypto.deriveKey(
      deviceId1: SettingsStore().syncLocalDeviceId,
      deviceId2: peerId,
      pin: pending.pin,
    );
    await _savePeer(PairedPeer(
      id: peerId,
      name: pending.peerName,
      keyBase64: await SyncCrypto.keyToBase64(key),
    ));
    _pendingPairings.remove(peerId);

    await conn.send(SyncMessage(
      type: SyncMessageType.pairingAck,
      senderId: SettingsStore().syncLocalDeviceId,
      senderName: _deviceName(),
    ));
    notifyListeners();

    if (SettingsStore().autoSync) {
      await _syncItems(conn, key);
    }
  }

  Future<void> rejectPairing(String peerId) async {
    final conn = _connections[peerId];
    _pendingPairings.remove(peerId);
    await conn?.send(SyncMessage(
      type: SyncMessageType.pairingReject,
      senderId: SettingsStore().syncLocalDeviceId,
      senderName: _deviceName(),
    ));
    await conn?.close();
    _connections.remove(peerId);
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
    final payload = jsonEncode(textItems.map((i) => i.toJson()).toList());
    final encrypted = await SyncCrypto.encrypt(payload, key);
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
}

class _PendingPairing {
  final String peerId;
  final String peerName;
  final String pin;
  _PendingPairing({required this.peerId, required this.peerName, required this.pin});
}
