import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:multicast_dns/multicast_dns.dart';
import '../core/app_logger.dart';
import 'sync_cadence_scheduler.dart';

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
  SyncCadenceScheduler? _broadcastCadence;
  SyncCadenceScheduler? _mdnsCadence;
  MDnsClient? _mdnsClient;
  final _peerCtrl = StreamController<DiscoveredPeer>.broadcast();
  Stream<DiscoveredPeer> get peers => _peerCtrl.stream;
  InternetAddress? _localAddress;

  Future<void> start({
    required String localId,
    required String localName,
    required int serverPort,
  }) async {
    _logInfo('start broadcast fallback localId=$localId localName=$localName serverPort=$serverPort');
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
      _logInfo('mDNS client started');
    } catch (error) {
      _logWarn('mDNS client failed to start error=$error');
      client.stop();
      return;
    }

    Future<void> queryOnce() async {
      try {
        await for (final PtrResourceRecord ptr in client.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer('$_serviceType.local'),
        )) {
          _logDebug('mDNS PTR discovered domainName=${ptr.domainName}');
          final id = _extractPeerId(ptr.domainName);
          if (id == null) {
            _logDebug('mDNS PTR ignored because peer id could not be extracted domainName=${ptr.domainName}');
            continue;
          }
          if (id == localId) {
            _logDebug('mDNS PTR ignored because it is the local service id=$id');
            continue;
          }

          final serviceName = _stripTrailingDot(ptr.domainName);
          final srvRecords = await client
              .lookup<SrvResourceRecord>(ResourceRecordQuery.service(serviceName))
              .toList();
          if (srvRecords.isEmpty) {
            _logDebug('mDNS SRV lookup returned no results id=$id serviceName=$serviceName');
            continue;
          }

          for (final srv in srvRecords) {
            _logDebug('mDNS SRV discovered id=$id target=${srv.target} port=${srv.port}');
            final addressName = _stripTrailingDot(srv.target);
            final ipRecords = await client
                .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(addressName))
                .toList();
            if (ipRecords.isEmpty) {
              _logDebug('mDNS A lookup returned no results id=$id target=$addressName');
              continue;
            }

            for (final ip in ipRecords) {
              _logDebug('mDNS A discovered id=$id target=${srv.target} address=${ip.address.address}');
              if (!_isPrivateLanAddress(ip.address.address)) {
                _logDebug('mDNS A ignored because address is not private LAN id=$id address=${ip.address.address}');
                continue;
              }
              final peer = DiscoveredPeer(
                id: id,
                name: id,
                host: ip.address.address,
                port: srv.port,
              );
              _logDebug('mDNS peer discovered id=${peer.id} host=${peer.host} port=${peer.port}');
              _peerCtrl.add(peer);
            }
          }
        }
      } catch (error) {
        _logWarn('mDNS lookup failed error=$error');
      }
    }

    await queryOnce();
    _mdnsCadence?.stop();
    _mdnsCadence = SyncCadenceScheduler(
      action: queryOnce,
      onPhaseChanged: (phase) {
        if (phase == SyncCadencePhase.burst) {
          _logInfo('mDNS cadence entered burst mode');
        } else {
          _logInfo('mDNS cadence switched to steady interval');
        }
      },
    )..start(fireImmediately: false);
  }

  Future<void> _startBroadcastDiscovery({
    required String localId,
    required String localName,
    required int serverPort,
  }) async {
    _logInfo('starting UDP broadcast discovery on port=$_broadcastPort');
    _localAddress = await _discoverPreferredLocalIpv4();
    _logInfo('selectedIPv4=${_localAddress?.address ?? "unavailable"}');

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
    _logInfo(
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
        _logDebug('broadcast announce id=$localId name=$localName port=$serverPort host=${_localAddress?.address ?? "packet-source"}');
      } on SocketException catch (error) {
        _logWarn('broadcast announce failed error=$error');
      }
    }

    announce();
    _broadcastCadence?.stop();
    _broadcastCadence = SyncCadenceScheduler(
      action: announce,
      onPhaseChanged: (phase) {
        if (phase == SyncCadencePhase.burst) {
          _logInfo('broadcast cadence entered burst mode');
        } else {
          _logInfo('broadcast cadence switched to steady interval');
        }
      },
    )..start(fireImmediately: false);
  }

  void _handleBroadcastDatagram(Datagram datagram, String localId) {
    try {
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
      _logDebug('broadcast peer discovered id=$id name=$name host=$host sender=${datagram.address.address} port=$port');
    } catch (_) {
      // Ignore malformed broadcast packets from unrelated applications.
    }
  }

  Future<void> stop() async {
    _mdnsCadence?.stop();
    _mdnsCadence = null;
    _mdnsClient?.stop();
    _mdnsClient = null;
    _broadcastCadence?.stop();
    _broadcastCadence = null;
    _broadcastReceiveSocket?.close();
    _broadcastReceiveSocket = null;
    _broadcastSendSocket?.close();
    _broadcastSendSocket = null;
    _localAddress = null;
  }

  void boostDiscovery() {
    _mdnsCadence?.retriggerBurst(fireImmediately: true);
    _broadcastCadence?.retriggerBurst(fireImmediately: true);
  }

  String? _extractPeerId(String domainName) {
    const suffix = '.$_serviceType.local';
    final canonicalName = _canonicalMdnsName(domainName);
    if (!canonicalName.endsWith(suffix)) return null;
    final stripped = _stripTrailingDot(domainName);
    return stripped.substring(0, stripped.length - suffix.length);
  }

  String _stripTrailingDot(String name) {
    return name.endsWith('.') ? name.substring(0, name.length - 1) : name;
  }

  String _canonicalMdnsName(String name) {
    return _stripTrailingDot(name).toLowerCase();
  }

  Future<InternetAddress?> _discoverPreferredLocalIpv4() async {
    final interfaces = await NetworkInterface.list(
      includeLinkLocal: true,
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );

    final candidates = <_BroadcastAddressCandidate>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.type != InternetAddressType.IPv4 || address.isLoopback) continue;
        if (!_isPrivateLanAddress(address.address)) continue;
        if (_looksVirtualInterface(interface.name)) continue;
        candidates.add(_BroadcastAddressCandidate(
          interfaceName: interface.name,
          address: address,
        ));
      }
    }

    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final scoreCompare =
          _interfacePriority(b.interfaceName).compareTo(_interfacePriority(a.interfaceName));
      if (scoreCompare != 0) return scoreCompare;
      return a.address.address.compareTo(b.address.address);
    });

    return candidates.first.address;
  }

  bool _isPrivateLanAddress(String address) {
    if (address.startsWith('10.')) return true;
    if (address.startsWith('192.168.')) return true;
    if (!address.startsWith('172.')) return false;

    final parts = address.split('.');
    if (parts.length < 2) return false;
    final secondOctet = int.tryParse(parts[1]);
    return secondOctet != null && secondOctet >= 16 && secondOctet <= 31;
  }

  bool _looksVirtualInterface(String name) {
    final normalized = name.toLowerCase();
    const blockedTokens = [
      'virtual',
      'vmware',
      'hyper-v',
      'hyperv',
      'wsl',
      'docker',
      'vbox',
      'vethernet',
      'vpn',
      'tun',
      'tap',
      'tailscale',
      'zerotier',
      'utun',
      'bridge',
      'loopback',
    ];
    return blockedTokens.any(normalized.contains);
  }

  int _interfacePriority(String name) {
    final normalized = name.toLowerCase();
    if (normalized.contains('wi-fi') || normalized.contains('wifi') || normalized.contains('wlan')) {
      return 3;
    }
    if (normalized.contains('ethernet') || normalized.startsWith('en')) {
      return 2;
    }
    return 1;
  }

  void _logDebug(String message) => AppLogger.instance.debug('SyncDiscovery', message);
  void _logInfo(String message) => AppLogger.instance.info('SyncDiscovery', message);
  void _logWarn(String message) => AppLogger.instance.warn('SyncDiscovery', message);
}

class _BroadcastAddressCandidate {
  final String interfaceName;
  final InternetAddress address;

  _BroadcastAddressCandidate({
    required this.interfaceName,
    required this.address,
  });
}
