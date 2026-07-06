import 'dart:convert';

enum SyncMessageType { hello, items, ack, ping, pong }

class SyncMessage {
  final SyncMessageType type;
  final String senderId;
  final String senderName;
  final String? encryptedPayload;

  SyncMessage({
    required this.type,
    required this.senderId,
    required this.senderName,
    this.encryptedPayload,
  });

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'senderID': senderId,
    'senderName': senderName,
    if (encryptedPayload != null) 'encryptedPayload': encryptedPayload,
  };

  factory SyncMessage.fromJson(Map<String, dynamic> json) {
    return SyncMessage(
      type: SyncMessageType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => SyncMessageType.ping,
      ),
      senderId: (json['senderID'] ?? json['senderId']) as String? ?? '',
      senderName: json['senderName'] as String? ?? '',
      encryptedPayload: json['encryptedPayload'] as String?,
    );
  }

  String encode() => jsonEncode(toJson());

  static SyncMessage decode(String s) =>
      SyncMessage.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
