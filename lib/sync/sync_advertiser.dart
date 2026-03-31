import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

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
  Timer? _announceTimer;

  late String _instanceName;
  late String _serviceTypeFqdn;
  late String _hostName;
  late int _serverPort;
  final List<InternetAddress> _ipv4Addresses = [];

  Future<void> start({
    required String localId,
    required String localName,
    required int serverPort,
  }) async {
    _serviceTypeFqdn = '$_serviceType.local';
    _instanceName = '$localId.$_serviceTypeFqdn';
    _hostName = '${_sanitizeHostLabel(localName)}.local';
    _serverPort = serverPort;

    _ipv4Addresses
      ..clear()
      ..addAll(await _discoverLocalIpv4Addresses());

    _log('localId=$localId localName=$localName');
    _log('service=$_instanceName host=$_hostName port=$serverPort');
    _log('selectedIPv4=${_ipv4Addresses.map((e) => e.address).join(", ")}');

    if (_ipv4Addresses.isEmpty) {
      _log('no eligible private IPv4 address found; mDNS advertisement disabled');
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
      _log('failed to bind UDP/5353; falling back to broadcast discovery only');
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
      _handleQuery(datagram);
    });

    _sendAnnouncement();
    _log('announcement sent');
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) {
        _log('periodic announcement');
        _sendAnnouncement();
      },
    );
  }

  void _log(String message) {
    if (kDebugMode) {
      debugPrint('[SyncAdvertiser] $message');
    }
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _socket?.close();
    _socket = null;
    _ipv4Addresses.clear();
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
