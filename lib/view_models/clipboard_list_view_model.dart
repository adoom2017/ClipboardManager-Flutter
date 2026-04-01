import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import '../models/clipboard_item.dart';
import '../storage/clipboard_store.dart';
import '../core/auto_paste_service.dart';

class ClipboardListViewModel extends ChangeNotifier {
  final ClipboardStore _store = ClipboardStore();
  String _searchQuery = '';

  ClipboardListViewModel() {
    _store.addListener(_onStoreChanged);
  }

  void _onStoreChanged() => notifyListeners();

  String get searchQuery => _searchQuery;

  void setSearch(String q) {
    _searchQuery = q;
    notifyListeners();
  }

  List<ClipboardItem> get filteredItems {
    if (_searchQuery.isEmpty) return _store.items;
    final q = _searchQuery.toLowerCase();
    return _store.items
        .where((i) =>
            i.content.toLowerCase().contains(q) ||
            i.sourceApp.toLowerCase().contains(q))
        .toList();
  }

  Future<void> pasteItem(ClipboardItem item) async {
    // Hide our window first so the target window can receive the paste
    if (Platform.isWindows) {
      await windowManager.hide();
    }
    await AutoPasteService.paste(item.content);
  }

  Future<void> togglePin(String id) => _store.togglePin(id);
  Future<void> removeItem(String id) => _store.removeItem(id);
  Future<void> clearAll() => _store.clearAll();

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    super.dispose();
  }
}
