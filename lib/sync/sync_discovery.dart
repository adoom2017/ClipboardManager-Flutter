import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:multicast_dns/multicast_dns.dart';

const _serviceType = '_clipmgr._tcp';
const _broadcastPort = 44561;
const _broadcastSignature = 'clipmgr-sync-v1';
const _serviceTypeFqdn = '$_serviceType.local';

class DiscoveredPeer {
  final String id;
  final String name;
  final String host;
  final int port;
  DiscoveredPeer({required this.id, required this.name, required this.host, required this.port});
}

class SyncDiscovery {
  MDnsClient? _client;
  StreamSubscription? _sub;
  RawDatagramSocket? _broadcastSocket;
  Timer? _announceTimer;
  final _peerCtrl = StreamController<DiscoveredPeer>.broadcast();
  Stream<DiscoveredPeer> get peers => _peerCtrl.stream;

  Future<RawDatagramSocket> _bindSocket(
    dynamic host,
    int port, {
    bool reuseAddress = true,
    bool reusePort = true,
    int ttl = 255,
  }) {
    return RawDatagramSocket.bind(
      host,
      port,
      reuseAddress: reuseAddress,
      // Windows does not support reusePort for multicast_dns' default setup.
      reusePort: Platform.isWindows ? false : reusePort,
      ttl: ttl,
    );
  }

  Future<Iterable<NetworkInterface>> _interfacesFactory(
    InternetAddressType type,
  ) async {
    final interfaces = await NetworkInterface.list(
      includeLinkLocal: true,
      includeLoopback: false,
      type: type,
    );

    return interfaces.where((interface) {
      if (interface.addresses.isEmpty) return false;
      return interface.addresses.any((address) => address.type == type);
    });
  }

  Future<void> start({
    required String localId,
    required String localName,
    required int serverPort,
  }) async {
    await _startBroadcastDiscovery(
      localId: localId,
      localName: localName,
      serverPort: serverPort,
    );

    _client = MDnsClient(rawDatagramSocketFactory: _bindSocket);
    try {
      await _client!.start(interfacesFactory: _interfacesFactory);
    } on SocketException {
      _client = null;
      return;
    } on OSError {
      _client = null;
      return;
    } catch (_) {
      _client = null;
      return;
    }

    // Discover peers
    _sub = _client!
        .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(_serviceType))
        .listen((ptr) async {
      final discoveredId = _extractId(ptr.domainName);
      if (discoveredId == null || discoveredId == localId) return;

      await for (final srv in _client!
          .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))
          .timeout(const Duration(seconds: 2), onTimeout: (_) {})) {
        final target = srv.target;
        final port = srv.port;
        // Resolve IP
        await for (final ip in _client!
            .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(target))
            .timeout(const Duration(seconds: 2), onTimeout: (_) {})) {
          final name = discoveredId;
          _peerCtrl.add(DiscoveredPeer(
            id: discoveredId,
            name: name,
            host: ip.address.address,
            port: port,
          ));
          break;
        }
        break;
      }
    });
  }

  String? _extractId(String domainName) {
    final normalized = domainName.toLowerCase();
    final suffix = '.$_serviceTypeFqdn';
    if (normalized.endsWith(suffix)) {
      return domainName.substring(0, domainName.length - suffix.length);
    }
    final fallbackSuffix = '.$_serviceType';
    if (normalized.endsWith(fallbackSuffix)) {
      return domainName.substring(0, domainName.length - fallbackSuffix.length);
    }
    return null;
  }

  Future<void> _startBroadcastDiscovery({
    required String localId,
    required String localName,
    required int serverPort,
  }) async {
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
    }

    announce();
    _announceTimer = Timer.periodic(const Duration(seconds: 2), (_) => announce());
  }

  void _handleBroadcastDatagram(Datagram datagram, String localId) {
    try {
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
    } catch (_) {
      // Ignore malformed broadcast packets from unrelated applications.
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _announceTimer?.cancel();
    _announceTimer = null;
    _broadcastSocket?.close();
    _broadcastSocket = null;
    _client?.stop();
    _client = null;
  }
}
