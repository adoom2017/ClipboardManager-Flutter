import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../core/app_logger.dart';
import 'sync_discovery.dart';
import 'sync_cadence_scheduler.dart';

const _serviceType = '_clipmgr._tcp';
const _mdnsTtlSeconds = 120;
final _mDnsAddressIPv4 = InternetAddress('224.0.0.251');
const _mDnsPort = 5353;
const _resourceRecordClassInternet = 1;
const _questionTypeUnicast = 0x8000;
const _resourceRecordTypeAddressIPv4 = 1;
const _resourceRecordTypeServerPointer = 12;
const _resourceRecordTypeText = 16;
const _resourceRecordTypeService = 33;

class SyncAdvertiser {
  RawDatagramSocket? _socket;
  SyncCadenceScheduler? _cadenceScheduler;
  final StreamController<DiscoveredPeer> _peerCtrl =
      StreamController<DiscoveredPeer>.broadcast();
  Stream<DiscoveredPeer> get peers => _peerCtrl.stream;

  late String _instanceName;
  late String _serviceTypeFqdn;
  late String _hostName;
  late int _serverPort;
  late String _localId;
  final List<InternetAddress> _ipv4Addresses = [];

  Future<void> start({
    required String localId,
    required String localName,
    required int serverPort,
  }) async {
    _localId = localId;
    _serviceTypeFqdn = '$_serviceType.local';
    _instanceName = '$localId.$_serviceTypeFqdn';
    _hostName = '${_sanitizeHostLabel(localName)}.local';
    _serverPort = serverPort;

    _ipv4Addresses
      ..clear()
      ..addAll(await _discoverLocalIpv4Addresses());

    _logInfo('localId=$localId localName=$localName');
    _logInfo('service=$_instanceName host=$_hostName port=$serverPort');
    _logInfo('selectedIPv4=${_ipv4Addresses.map((e) => e.address).join(", ")}');

    if (_ipv4Addresses.isEmpty) {
      _logWarn('no eligible private IPv4 address found; mDNS advertisement disabled');
      return;
    }

    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _mDnsPort,
        reuseAddress: true,
        reusePort: false,
        ttl: 255,
      );
    } on SocketException {
      // If another mDNS responder already owns the port we keep the app usable
      // and fall back to the UDP broadcast discovery path.
      _logWarn('failed to bind UDP/5353; falling back to broadcast discovery only');
      return;
    }

    final interfaces = await NetworkInterface.list(
      includeLinkLocal: true,
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      try {
        _socket!.joinMulticast(_mDnsAddressIPv4, interface);
      } catch (_) {
        // Ignore interfaces that reject multicast joins.
      }
    }

    _socket!
      ..broadcastEnabled = false
      ..readEventsEnabled = true
      ..writeEventsEnabled = false;

    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket!.receive();
      if (datagram == null) return;
      _handleMdnsResponse(datagram);
      _handleQuery(datagram);
    });

    _sendAnnouncement();
    _sendDiscoveryQuery();
    _logInfo('mDNS advertiser started');
    _cadenceScheduler?.stop();
    _cadenceScheduler = SyncCadenceScheduler(
      action: () {
        _sendAnnouncement();
        _sendDiscoveryQuery();
      },
      onPhaseChanged: (phase) {
        if (phase == SyncCadencePhase.burst) {
          _logInfo('advertiser cadence entered burst mode');
        } else {
          _logInfo('advertiser cadence switched to steady interval');
        }
      },
    )..start(fireImmediately: false);
  }

  Future<void> stop() async {
    _cadenceScheduler?.stop();
    _cadenceScheduler = null;
    _socket?.close();
    _socket = null;
    _ipv4Addresses.clear();
  }

  void boostDiscovery() {
    _cadenceScheduler?.retriggerBurst(fireImmediately: true);
  }

  Future<List<InternetAddress>> _discoverLocalIpv4Addresses() async {
    final interfaces = await NetworkInterface.list(
      includeLinkLocal: true,
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );

    final candidates = <_AdvertiseAddressCandidate>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.type != InternetAddressType.IPv4 || address.isLoopback) continue;
        if (!_isPrivateLanAddress(address.address)) continue;
        if (_looksVirtualInterface(interface.name)) continue;

        candidates.add(
          _AdvertiseAddressCandidate(
            interfaceName: interface.name,
            address: address,
          ),
        );
      }
    }

    if (candidates.isEmpty) return const [];

    candidates.sort((a, b) {
      final scoreCompare = _interfacePriority(b.interfaceName)
          .compareTo(_interfacePriority(a.interfaceName));
      if (scoreCompare != 0) return scoreCompare;
      return a.address.address.compareTo(b.address.address);
    });

    final selected = candidates.first;
    return [selected.address];
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

  String _sanitizeHostLabel(String input) {
    final trimmed = input.trim();
    final fallback = trimmed.isEmpty ? 'clipboard-manager' : trimmed;
    final sanitized = fallback
        .replaceAll(RegExp(r'[^A-Za-z0-9-]'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return sanitized.isEmpty ? 'clipboard-manager' : sanitized.toLowerCase();
  }

  void _handleQuery(Datagram datagram) {
    final query = _decodeMdnsQuery(datagram.data);
    if (query == null) return;
    _logDebug('received mDNS query type=${query.resourceRecordType} name=${query.fullyQualifiedName} from=${datagram.address.address}:${datagram.port}');

    final answers = <_DnsRecord>[];
    final additionals = <_DnsRecord>[];
    final fqdn = query.fullyQualifiedName.toLowerCase();

    if (query.resourceRecordType == _resourceRecordTypeServerPointer &&
        fqdn == _serviceTypeFqdn) {
      answers.add(_ptrRecord(_serviceTypeFqdn, _instanceName));
      additionals.add(_srvRecord());
      additionals.add(_txtRecord());
      additionals.addAll(_aRecords());
    } else if (query.resourceRecordType == _resourceRecordTypeService &&
        fqdn == _instanceName.toLowerCase()) {
      answers.add(_srvRecord());
      additionals.add(_txtRecord());
      additionals.addAll(_aRecords());
    } else if (query.resourceRecordType == _resourceRecordTypeText &&
        fqdn == _instanceName.toLowerCase()) {
      answers.add(_txtRecord());
    } else if (query.resourceRecordType == _resourceRecordTypeAddressIPv4 &&
        fqdn == _hostName.toLowerCase()) {
      answers.addAll(_aRecords());
    }

    if (answers.isEmpty) return;
    _sendResponse(
      answers: answers,
      additionals: additionals,
      destination: query.isUnicast ? datagram.address : _mDnsAddressIPv4,
      port: query.isUnicast ? datagram.port : _mDnsPort,
    );
  }

  void _sendAnnouncement() {
    if (_socket == null) return;
    _sendResponse(
      answers: [
        _ptrRecord(_serviceTypeFqdn, _instanceName),
        _srvRecord(),
        _txtRecord(),
        ..._aRecords(),
      ],
      additionals: const [],
      destination: _mDnsAddressIPv4,
      port: _mDnsPort,
    );
  }

  void _sendDiscoveryQuery() {
    if (_socket == null) return;
    final builder = BytesBuilder();
    final header = ByteData(12)
      ..setUint16(0, 0)
      ..setUint16(2, 0)
      ..setUint16(4, 1)
      ..setUint16(6, 0)
      ..setUint16(8, 0)
      ..setUint16(10, 0);
    builder.add(header.buffer.asUint8List());
    builder.add(_encodeDnsName(_serviceTypeFqdn));
    final question = ByteData(4)
      ..setUint16(0, _resourceRecordTypeServerPointer)
      ..setUint16(2, _resourceRecordClassInternet);
    builder.add(question.buffer.asUint8List());
    _socket!.send(builder.toBytes(), _mDnsAddressIPv4, _mDnsPort);
    _logDebug('sent PTR discovery query for $_serviceTypeFqdn');
  }

  void _sendResponse({
    required List<_DnsRecord> answers,
    required List<_DnsRecord> additionals,
    required InternetAddress destination,
    required int port,
  }) {
    if (_socket == null) return;
    final packet = _buildDnsResponse(answers, additionals);
    _socket!.send(packet, destination, port);
  }

  void _handleMdnsResponse(Datagram datagram) {
    final packet = _decodeMdnsPacket(datagram.data);
    if (packet == null) return;
    if (!packet.isResponse || packet.answers.isEmpty) return;
    _logDebug('received mDNS response answers=${packet.answers.length} from=${datagram.address.address}:${datagram.port}');

    final ptrTargets = <String>{};
    final srvRecords = <String, _SrvRecordData>{};
    final aRecords = <String, InternetAddress>{};

    for (final answer in packet.answers) {
      switch (answer.type) {
        case _resourceRecordTypeServerPointer:
          if (answer.name.toLowerCase() != _serviceTypeFqdn) continue;
          final target = _readDnsName(
            packet.rawData,
            packet.byteData,
            answer.dataOffset,
          )?.name;
          if (target != null) {
            _logDebug('PTR answer name=${answer.name} target=$target');
            ptrTargets.add(target);
          }
          break;
        case _resourceRecordTypeService:
          if (answer.dataLength < 6) continue;
          final port = packet.byteData.getUint16(answer.dataOffset + 4);
          final target = _readDnsName(
            packet.rawData,
            packet.byteData,
            answer.dataOffset + 6,
          )?.name;
          if (target != null) {
            _logDebug('SRV answer name=${answer.name} target=$target port=$port');
            srvRecords[answer.name.toLowerCase()] =
                _SrvRecordData(target: target, port: port);
          }
          break;
        case _resourceRecordTypeAddressIPv4:
          if (answer.dataLength != 4) continue;
          final address = InternetAddress.fromRawAddress(
              packet.rawData.sublist(answer.dataOffset, answer.dataOffset + 4),
              type: InternetAddressType.IPv4);
          _logDebug('A answer name=${answer.name} address=${address.address}');
          aRecords[answer.name.toLowerCase()] = address;
          break;
      }
    }

    for (final instanceName in ptrTargets) {
      final id = _extractInstanceId(instanceName);
      if (id == null || id == _localId) continue;
      final srv = srvRecords[instanceName.toLowerCase()];
      final ip = srv == null
          ? null
          : aRecords[srv.target.toLowerCase()] ?? datagram.address;
      if (srv == null || ip == null || !_isPrivateLanAddress(ip.address)) continue;

      final peer = DiscoveredPeer(
        id: id,
        name: id,
        host: ip.address,
        port: srv.port,
      );
      _logDebug('mDNS peer discovered id=${peer.id} host=${peer.host} port=${peer.port}');
      _peerCtrl.add(peer);
    }
  }

  Uint8List _buildDnsResponse(
    List<_DnsRecord> answers,
    List<_DnsRecord> additionals,
  ) {
    final builder = BytesBuilder();
    final header = ByteData(12)
      ..setUint16(0, 0)
      ..setUint16(2, 0x8400)
      ..setUint16(4, 0)
      ..setUint16(6, answers.length)
      ..setUint16(8, 0)
      ..setUint16(10, additionals.length);
    builder.add(header.buffer.asUint8List());
    for (final record in answers) {
      builder.add(_encodeRecord(record));
    }
    for (final record in additionals) {
      builder.add(_encodeRecord(record));
    }
    return builder.toBytes();
  }

  Uint8List _encodeRecord(_DnsRecord record) {
    final builder = BytesBuilder();
    builder.add(_encodeDnsName(record.name));

    final meta = ByteData(10)
      ..setUint16(0, record.type)
      ..setUint16(2, record.recordClass | 0x8000)
      ..setUint32(4, record.ttl)
      ..setUint16(8, record.data.length);
    builder.add(meta.buffer.asUint8List());
    builder.add(record.data);
    return builder.toBytes();
  }

  Uint8List _encodeDnsName(String name) {
    final normalized = name.endsWith('.') ? name.substring(0, name.length - 1) : name;
    final builder = BytesBuilder();
    for (final part in normalized.split('.')) {
      final bytes = utf8.encode(part);
      builder.add([bytes.length]);
      builder.add(bytes);
    }
    builder.add([0]);
    return builder.toBytes();
  }

  _DnsRecord _ptrRecord(String name, String domainName) {
    return _DnsRecord(
      name: name,
      type: _resourceRecordTypeServerPointer,
      recordClass: _resourceRecordClassInternet,
      ttl: _mdnsTtlSeconds,
      data: _encodeDnsName(domainName),
    );
  }

  _DnsRecord _srvRecord() {
    final targetName = _encodeDnsName(_hostName);
    final data = ByteData(6)
      ..setUint16(0, 0)
      ..setUint16(2, 0)
      ..setUint16(4, _serverPort);
    return _DnsRecord(
      name: _instanceName,
      type: _resourceRecordTypeService,
      recordClass: _resourceRecordClassInternet,
      ttl: _mdnsTtlSeconds,
      data: Uint8List.fromList([
        ...data.buffer.asUint8List(),
        ...targetName,
      ]),
    );
  }

  _DnsRecord _txtRecord() {
    final entries = [
      'id=${_instanceName.split('.').first}',
      'ver=1',
    ];
    final builder = BytesBuilder();
    for (final entry in entries) {
      final bytes = utf8.encode(entry);
      builder.add([bytes.length]);
      builder.add(bytes);
    }
    return _DnsRecord(
      name: _instanceName,
      type: _resourceRecordTypeText,
      recordClass: _resourceRecordClassInternet,
      ttl: _mdnsTtlSeconds,
      data: builder.toBytes(),
    );
  }

  List<_DnsRecord> _aRecords() {
    return _ipv4Addresses
        .map(
          (address) => _DnsRecord(
            name: _hostName,
            type: _resourceRecordTypeAddressIPv4,
            recordClass: _resourceRecordClassInternet,
            ttl: _mdnsTtlSeconds,
            data: Uint8List.fromList(address.rawAddress),
          ),
        )
        .toList();
  }

  _DnsQuery? _decodeMdnsQuery(List<int> packet) {
    if (packet.length < 12) return null;
    final data = packet is Uint8List ? packet : Uint8List.fromList(packet);
    final byteData = ByteData.view(data.buffer);
    final flags = byteData.getUint16(2);
    if (flags != 0) return null;

    final questionCount = byteData.getUint16(4);
    if (questionCount == 0) return null;

    final nameResult = _readDnsName(data, byteData, 12);
    if (nameResult == null) return null;

    var offset = 12 + nameResult.bytesRead;
    if (offset + 4 > data.length) return null;

    final type = byteData.getUint16(offset);
    offset += 2;
    final questionType = byteData.getUint16(offset) & _questionTypeUnicast;
    return _DnsQuery(
      resourceRecordType: type,
      fullyQualifiedName: nameResult.name.toLowerCase(),
      isUnicast: questionType == _questionTypeUnicast,
    );
  }

  _DecodedDnsPacket? _decodeMdnsPacket(List<int> packet) {
    if (packet.length < 12) return null;
    final data = packet is Uint8List ? packet : Uint8List.fromList(packet);
    final byteData = ByteData.view(data.buffer);
    final flags = byteData.getUint16(2);
    final questionCount = byteData.getUint16(4);
    final answerCount = byteData.getUint16(6);
    final authorityCount = byteData.getUint16(8);
    final additionalCount = byteData.getUint16(10);

    var offset = 12;
    for (var i = 0; i < questionCount; i++) {
      final nameResult = _readDnsName(data, byteData, offset);
      if (nameResult == null) return null;
      offset += nameResult.bytesRead + 4;
      if (offset > data.length) return null;
    }

    final answers = <_DecodedResourceRecord>[];
    final recordCount = answerCount + authorityCount + additionalCount;
    for (var i = 0; i < recordCount; i++) {
      final nameResult = _readDnsName(data, byteData, offset);
      if (nameResult == null) return null;
      offset += nameResult.bytesRead;
      if (offset + 10 > data.length) return null;

      final type = byteData.getUint16(offset);
      final recordClass = byteData.getUint16(offset + 2);
      final ttl = byteData.getUint32(offset + 4);
      final dataLength = byteData.getUint16(offset + 8);
      final dataOffset = offset + 10;
      offset = dataOffset + dataLength;
      if (offset > data.length) return null;

      answers.add(_DecodedResourceRecord(
        name: nameResult.name,
        type: type,
        recordClass: recordClass,
        ttl: ttl,
        dataOffset: dataOffset,
        dataLength: dataLength,
      ));
    }

    return _DecodedDnsPacket(
      rawData: data,
      byteData: byteData,
      isResponse: (flags & 0x8000) != 0,
      answers: answers,
    );
  }

  String? _extractInstanceId(String instanceName) {
    final normalized = instanceName.toLowerCase();
    final suffix = '.$_serviceTypeFqdn';
    if (!normalized.endsWith(suffix)) return null;
    return instanceName.substring(0, instanceName.length - suffix.length);
  }

  _DnsNameReadResult? _readDnsName(
    Uint8List data,
    ByteData byteData,
    int startOffset,
  ) {
    var offset = startOffset;
    final parts = <String>[];
    var consumed = 0;

    while (offset < data.length) {
      final length = data[offset];
      if ((length & 0xC0) == 0xC0) {
        if (offset + 1 >= data.length) return null;
        final pointer = byteData.getUint16(offset) & 0x3FFF;
        final pointed = _readDnsName(data, byteData, pointer);
        if (pointed == null) return null;
        parts.addAll(pointed.name.split('.'));
        consumed += 2;
        return _DnsNameReadResult(parts.join('.'), consumed);
      }

      offset++;
      consumed++;

      if (length == 0) {
        return _DnsNameReadResult(parts.join('.'), consumed);
      }

      if (offset + length > data.length) return null;
      parts.add(utf8.decode(data.sublist(offset, offset + length), allowMalformed: true));
      offset += length;
      consumed += length;
    }

    return null;
  }

  void _logDebug(String message) => AppLogger.instance.debug('SyncAdvertiser', message);
  void _logInfo(String message) => AppLogger.instance.info('SyncAdvertiser', message);
  void _logWarn(String message) => AppLogger.instance.warn('SyncAdvertiser', message);
}

class _DnsRecord {
  const _DnsRecord({
    required this.name,
    required this.type,
    required this.recordClass,
    required this.ttl,
    required this.data,
  });

  final String name;
  final int type;
  final int recordClass;
  final int ttl;
  final Uint8List data;
}

class _DecodedDnsPacket {
  const _DecodedDnsPacket({
    required this.rawData,
    required this.byteData,
    required this.isResponse,
    required this.answers,
  });

  final Uint8List rawData;
  final ByteData byteData;
  final bool isResponse;
  final List<_DecodedResourceRecord> answers;
}

class _DecodedResourceRecord {
  const _DecodedResourceRecord({
    required this.name,
    required this.type,
    required this.recordClass,
    required this.ttl,
    required this.dataOffset,
    required this.dataLength,
  });

  final String name;
  final int type;
  final int recordClass;
  final int ttl;
  final int dataOffset;
  final int dataLength;
}

class _SrvRecordData {
  const _SrvRecordData({
    required this.target,
    required this.port,
  });

  final String target;
  final int port;
}

class _AdvertiseAddressCandidate {
  const _AdvertiseAddressCandidate({
    required this.interfaceName,
    required this.address,
  });

  final String interfaceName;
  final InternetAddress address;
}

class _DnsQuery {
  const _DnsQuery({
    required this.resourceRecordType,
    required this.fullyQualifiedName,
    required this.isUnicast,
  });

  final int resourceRecordType;
  final String fullyQualifiedName;
  final bool isUnicast;
}

class _DnsNameReadResult {
  const _DnsNameReadResult(this.name, this.bytesRead);

  final String name;
  final int bytesRead;
}
