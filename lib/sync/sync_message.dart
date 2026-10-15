import 'dart:convert';

enum SyncMessageType { hello, items, ack, ping, pong, error }

/// Reason codes carried by `error` messages. Unknown codes map to null.
enum SyncErrorCode {
  pinNotConfigured,
  decryptFailed,
  invalidPayload;

  static SyncErrorCode? parse(String? value) {
    for (final code in values) {
      if (code.name == value) return code;
    }
    return null;
  }

  String userMessage(String peerName) => switch (this) {
    SyncErrorCode.pinNotConfigured => '$peerName 尚未配置同步 PIN。',
    SyncErrorCode.decryptFailed => '$peerName 无法解密，请确认两端同步 PIN 一致。',
    SyncErrorCode.invalidPayload => '$peerName 无法解析同步内容，请确认两端均为最新版本。',
  };
}

class SyncMessage {
  final SyncMessageType type;
  final String senderId;
  final String senderName;
  final String? encryptedPayload;
  final String? errorCode;

  SyncMessage({
    required this.type,
    required this.senderId,
    required this.senderName,
    this.encryptedPayload,
    this.errorCode,
  });

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'senderID': senderId,
    'senderName': senderName,
    if (encryptedPayload != null) 'encryptedPayload': encryptedPayload,
    if (errorCode != null) 'errorCode': errorCode,
  };

  factory SyncMessage.fromJson(Map<String, dynamic> json) {
    return SyncMessage(
      // Unknown types are rejected (and dropped by SyncConnection) rather
      // than being treated as a ping.
      type: SyncMessageType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () =>
            throw FormatException('unknown sync message type ${json['type']}'),
      ),
      senderId: (json['senderID'] ?? json['senderId']) as String? ?? '',
      senderName: json['senderName'] as String? ?? '',
      encryptedPayload: json['encryptedPayload'] as String?,
      errorCode: json['errorCode'] as String?,
    );
  }

  String encode() => jsonEncode(toJson());

  static SyncMessage decode(String s) =>
      SyncMessage.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
