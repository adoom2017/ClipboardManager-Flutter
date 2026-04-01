import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';

const _broadcastPort = 44561;
const _broadcastSignature = 'clipmgr-sync-v1';
const _serviceType = '_clipmgr._tcp';

class DiscoveredPeer {
  final String id;
  final String name;
  final String host;
  final int port;
  DiscoveredPeer({required this.id, required this.name, required this.host, required this.port});
}

class SyncDiscovery {
  RawDatagramSocket? _broadcastReceiveSocket;
  RawDatagramSocket? _broadcastSendSocket;
  Timer? _announceTimer;
  Timer? _mdnsQueryTimer;
  MDnsClient? _mdnsClient;
  final Set<String> _localAddresses = {};
  final _peerCtrl = StreamController<DiscoveredPeer>.broadcast();
  Stream<DiscoveredPeer> get peers => _peerCtrl.stream;
  InternetAddress? _localAddress;

  Future<void> start({
    required String localId,
    required String localName,
    required int serverPort,
  }) async {
    _localAddresses
      ..clear()
      ..addAll(await _discoverLocalIpv4Addresses());
    _log('start broadcast fallback localId=$localId localName=$localName serverPort=$serverPort');
    await _startMdnsDiscovery(localId);
    await _startBroadcastDiscovery(
      localId: localId,
      localName: localName,
      serverPort: serverPort,
    );
  }

  Future<void> _startMdnsDiscovery(String localId) async {
    if (!Platform.isMacOS) return;

    final client = MDnsClient();
    try {
      await client.start();
      _mdnsClient = client;
      _log('mDNS client started');
    } catch (error) {
      _log('mDNS client failed to start error=$error');
      client.stop();
      return;
    }

    Future<void> queryOnce() async {
      try {
        await for (final PtrResourceRecord ptr in client.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer('$_serviceType.local'),
        )) {
          _log('mDNS PTR discovered domainName=${ptr.domainName}');
          final id = _extractPeerId(ptr.domainName);
          if (id == null) {
            _log('mDNS PTR ignored because peer id could not be extracted domainName=${ptr.domainName}');
            continue;
          }
          if (id == localId) {
            _log('mDNS PTR ignored because it is the local service id=$id');
            continue;
          }

          final serviceName = _stripTrailingDot(ptr.domainName);
          final srvRecords = await client
              .lookup<SrvResourceRecord>(ResourceRecordQuery.service(serviceName))
              .toList();
          if (srvRecords.isEmpty) {
            _log('mDNS SRV lookup returned no results id=$id serviceName=$serviceName');
            continue;
          }

          for (final srv in srvRecords) {
            _log('mDNS SRV discovered id=$id target=${srv.target} port=${srv.port}');
            final addressName = _stripTrailingDot(srv.target);
            final ipRecords = await client
                .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(addressName))
                .toList();
            if (ipRecords.isEmpty) {
              _log('mDNS A lookup returned no results id=$id target=$addressName');
              continue;
            }

            for (final ip in ipRecords) {
              _log('mDNS A discovered id=$id target=${srv.target} address=${ip.address.address}');
              if (!_isPrivateLanAddress(ip.address.address)) {
                _log('mDNS A ignored because address is not private LAN id=$id address=${ip.address.address}');
                continue;
              }
              final peer = DiscoveredPeer(
                id: id,
                name: id,
                host: ip.address.address,
                port: srv.port,
              );
              _log('mDNS peer discovered id=${peer.id} host=${peer.host} port=${peer.port}');
              _peerCtrl.add(peer);
            }
          }
        }
      } catch (error) {
        _log('mDNS lookup failed error=$error');
      }
    }

    await queryOnce();
    _mdnsQueryTimer?.cancel();
    _mdnsQueryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(queryOnce());
    });
  }

  Future<void> _startBroadcastDiscovery({
    required String localId,
    required String localName,
    required int serverPort,
  }) async {
    _log('starting UDP broadcast discovery on port=$_broadcastPort');
    _localAddress = await _discoverPreferredLocalIpv4();
    _log('selectedIPv4=${_localAddress?.address ?? "unavailable"}');

    _broadcastReceiveSocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _broadcastPort,
      reuseAddress: true,
      reusePort: true,
    );
    _broadcastReceiveSocket!
      ..broadcastEnabled = false
      ..readEventsEnabled = true
      ..writeEventsEnabled = false;

    _broadcastReceiveSocket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _broadcastReceiveSocket!.receive();
      if (datagram == null) return;
      _handleBroadcastDatagram(datagram, localId);
    });

    final sendBindAddress = _localAddress ?? InternetAddress.anyIPv4;
    _broadcastSendSocket = await RawDatagramSocket.bind(
      sendBindAddress,
      0,
      reuseAddress: true,
      reusePort: true,
    );
    _broadcastSendSocket!
      ..broadcastEnabled = true
      ..readEventsEnabled = false
      ..writeEventsEnabled = false;
    _log(
      'broadcast sockets ready receive=${_broadcastReceiveSocket!.address.address}:${_broadcastReceiveSocket!.port} '
      'send=${_broadcastSendSocket!.address.address}:${_broadcastSendSocket!.port}',
    );

    void announce() {
      final payload = utf8.encode(jsonEncode({
        'signature': _broadcastSignature,
        'id': localId,
        'name': localName,
        'port': serverPort,
        if (_localAddress != null) 'host': _localAddress!.address,
      }));
      try {
        _broadcastSendSocket!.send(
          payload,
          InternetAddress('255.255.255.255'),
          _broadcastPort,
        );
        _log('broadcast announce id=$localId name=$localName port=$serverPort host=${_localAddress?.address ?? "packet-source"}');
      } on SocketException catch (error) {
        _log('broadcast announce failed error=$error');
      }
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
      final host = (payload['host'] as String?) ?? datagram.address.address;

      _peerCtrl.add(DiscoveredPeer(
        id: id,
        name: name,
        host: host,
        port: port,
      ));
      _log('broadcast peer discovered id=$id name=$name host=$host sender=${datagram.address.address} port=$port');
    } catch (_) {
      // Ignore malformed broadcast packets from unrelated applications.
    }
  }

  Future<void> stop() async {
    _mdnsQueryTimer?.cancel();
    _mdnsQueryTimer = null;
    _mdnsClient?.stop();
    _mdnsClient = null;
    _announceTimer?.cancel();
    _announceTimer = null;
    _broadcastSocket?.close();
    _broadcastSocket = null;
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

class _BroadcastAddressCandidate {
  final String interfaceName;
  final InternetAddress address;

  _BroadcastAddressCandidate({
    required this.interfaceName,
    required this.address,
  });
}
