import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/clipboard_item.dart';

class PersistenceController {
  static const _fileName = 'clipboard_history.json';

  Future<String> get _filePath async {
    final appData = Platform.environment['APPDATA'] ?? '';
    final dir = Directory('$appData\\ClipboardManager');
    if (!await dir.exists()) await dir.create(recursive: true);
    return '${dir.path}\\$_fileName';
  }

  Future<List<ClipboardItem>> load() async {
    try {
      final path = await _filePath;
      final file = File(path);
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      if (content.trim().isEmpty) return [];
      return ClipboardItem.listFromJson(content);
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<ClipboardItem> items) async {
    try {
      final path = await _filePath;
      await File(path).writeAsString(ClipboardItem.listToJson(items));
    } catch (_) {}
  }

  Future<void> delete() async {
    try {
      final path = await _filePath;
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
