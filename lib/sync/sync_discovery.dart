import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

const _broadcastPort = 44561;
const _broadcastSignature = 'clipmgr-sync-v1';

class DiscoveredPeer {
  final String id;
  final String name;
  final String host;
  final int port;
  DiscoveredPeer({required this.id, required this.name, required this.host, required this.port});
}

class SyncDiscovery {
  RawDatagramSocket? _broadcastSocket;
  Timer? _announceTimer;
  final Set<String> _localAddresses = {};
  final _peerCtrl = StreamController<DiscoveredPeer>.broadcast();
  Stream<DiscoveredPeer> get peers => _peerCtrl.stream;

  Future<void> start({
    required String localId,
    required String localName,
    required int serverPort,
  }) async {
    _localAddresses
      ..clear()
      ..addAll(await _discoverLocalIpv4Addresses());
    _log('start broadcast fallback localId=$localId localName=$localName serverPort=$serverPort');
    await _startBroadcastDiscovery(
      localId: localId,
      localName: localName,
      serverPort: serverPort,
    );
  }

  Future<void> _startBroadcastDiscovery({
    required String localId,
    required String localName,
    required int serverPort,
  }) async {
    _log('starting UDP broadcast discovery on port=$_broadcastPort');
    _broadcastSocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _broadcastPort,
      reuseAddress: true,
      reusePort: false,
    );
    _broadcastSocket!
      ..broadcastEnabled = true
      ..readEventsEnabled = true
      ..writeEventsEnabled = false;

    _broadcastSocket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _broadcastSocket!.receive();
      if (datagram == null) return;
      _handleBroadcastDatagram(datagram, localId);
    });

    void announce() {
      final payload = utf8.encode(jsonEncode({
        'signature': _broadcastSignature,
        'id': localId,
        'name': localName,
        'port': serverPort,
      }));
      _broadcastSocket!.send(
        payload,
        InternetAddress('255.255.255.255'),
        _broadcastPort,
      );
      _log('broadcast announce id=$localId name=$localName port=$serverPort');
    }

    announce();
    _announceTimer = Timer.periodic(const Duration(seconds: 2), (_) => announce());
  }

  void _handleBroadcastDatagram(Datagram datagram, String localId) {
    try {
      if (_isLocalAddress(datagram.address.address)) return;
      final payload = jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
      if (payload['signature'] != _broadcastSignature) return;

      final id = payload['id'] as String?;
      final name = payload['name'] as String?;
      final port = payload['port'] as int?;
      if (id == null || name == null || port == null || id == localId) return;

      _peerCtrl.add(DiscoveredPeer(
        id: id,
        name: name,
        host: datagram.address.address,
        port: port,
      ));
      _log('broadcast peer discovered id=$id name=$name host=${datagram.address.address} port=$port');
    } catch (_) {
      // Ignore malformed broadcast packets from unrelated applications.
    }
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _broadcastSocket?.close();
    _broadcastSocket = null;
    _localAddresses.clear();
  }

  Future<Set<String>> _discoverLocalIpv4Addresses() async {
    final interfaces = await NetworkInterface.list(
      includeLinkLocal: true,
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );

    final addresses = <String>{};
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.type == InternetAddressType.IPv4 && !address.isLoopback) {
          addresses.add(address.address);
        }
      }
    }
    return addresses;
  }

  bool _isLocalAddress(String address) => _localAddresses.contains(address);

  void _log(String message) {
    if (kDebugMode) {
      debugPrint('[SyncDiscovery] $message');
    }
  }
}
