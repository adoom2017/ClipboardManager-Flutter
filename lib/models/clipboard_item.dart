import 'dart:convert';

enum ClipboardContentType { text, image, file }

class ClipboardItem {
  final String id;
  final ClipboardContentType contentType;
  final String content;
  final DateTime timestamp;
  final String sourceApp;
  bool isPinned;
  final String? imageName;
  final List<String>? fileUrls;

  ClipboardItem({
    required this.id,
    required this.contentType,
    required this.content,
    required this.timestamp,
    required this.sourceApp,
    this.isPinned = false,
    this.imageName,
    this.fileUrls,
  });

  /// First 2 lines, truncated at 100 chars
  String get contentPreview {
    final lines = content.split('\n').take(2).join('\n');
    if (lines.length > 100) return '${lines.substring(0, 100)}…';
    return lines;
  }

  /// Chinese relative time
  String get relativeTime {
    final diff = DateTime.now().toUtc().difference(timestamp.toUtc());
    if (diff.inSeconds < 60) return '${diff.inSeconds}秒前';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    return '${diff.inDays}天前';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'contentType': contentType.name,
        'content': content,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'sourceApp': sourceApp,
        'isPinned': isPinned,
        'imageName': imageName,
        'fileUrls': fileUrls,
      };

  factory ClipboardItem.fromJson(Map<String, dynamic> json) {
    return ClipboardItem(
      id: json['id'] as String,
      contentType: ClipboardContentType.values.firstWhere(
        (e) => e.name == (json['contentType'] as String),
        orElse: () => ClipboardContentType.text,
      ),
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      sourceApp: json['sourceApp'] as String? ?? 'Unknown',
      isPinned: json['isPinned'] as bool? ?? false,
      imageName: json['imageName'] as String?,
      fileUrls: (json['fileUrls'] as List<dynamic>?)?.cast<String>(),
    );
  }

  static List<ClipboardItem> listFromJson(String src) {
    final list = jsonDecode(src) as List<dynamic>;
    return list.map((e) => ClipboardItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  static String listToJson(List<ClipboardItem> items) {
    return jsonEncode(items.map((e) => e.toJson()).toList());
  }

  ClipboardItem copyWith({bool? isPinned}) {
    return ClipboardItem(
      id: id,
      contentType: contentType,
      content: content,
      timestamp: timestamp,
      sourceApp: sourceApp,
      isPinned: isPinned ?? this.isPinned,
      imageName: imageName,
      fileUrls: fileUrls,
    );
  }
}
