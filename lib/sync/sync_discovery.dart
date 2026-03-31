import 'dart:async';
import 'dart:io';
import 'package:multicast_dns/multicast_dns.dart';

const _serviceType = '_clipmgr._tcp';

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
  final _peerCtrl = StreamController<DiscoveredPeer>.broadcast();
  Stream<DiscoveredPeer> get peers => _peerCtrl.stream;

  String? _localId;
  InternetAddress? _serverAddr;
  int _serverPort = 0;

  Future<void> start({required String localId}) async {
    _localId = localId;
    _client = MDnsClient();
    await _client!.start();

    // Discover peers
    _sub = _client!
        .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(_serviceType))
        .listen((ptr) async {
      if (ptr.domainName == '$localId.$_serviceType') return; // skip self

      await for (final srv in _client!
          .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))
          .timeout(const Duration(seconds: 2), onTimeout: (_) {})) {
        final target = srv.target;
        final port = srv.port;
        // Resolve IP
        await for (final ip in _client!
            .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(target))
            .timeout(const Duration(seconds: 2), onTimeout: (_) {})) {
          final name = ptr.domainName.replaceAll('.$_serviceType', '');
          _peerCtrl.add(DiscoveredPeer(
            id: name,
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

  Future<void> stop() async {
    await _sub?.cancel();
    _client?.stop();
    _client = null;
  }
}
