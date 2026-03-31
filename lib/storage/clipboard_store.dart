import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/clipboard_item.dart';
import 'persistence_controller.dart';
import 'settings_store.dart';

class ClipboardStore extends ChangeNotifier {
  static final ClipboardStore _instance = ClipboardStore._internal();
  factory ClipboardStore() => _instance;
  ClipboardStore._internal() {
    // Prune expired items every hour while the app is running
    Timer.periodic(const Duration(hours: 1), (_) => _pruneByAge());
  }

  final _persistence = PersistenceController();
  final List<ClipboardItem> _items = [];

  List<ClipboardItem> get items => List.unmodifiable(_items);

  Future<void> load() async {
    final loaded = await _persistence.load();
    _items.clear();
    _items.addAll(loaded);
    _pruneByAge(save: false); // clean on startup before notifying
    _sort();
    notifyListeners();
  }

  Future<void> addItem(ClipboardItem item) async {
    // Skip if content matches any pinned item
    if (_items.any((e) => e.isPinned && e.content == item.content)) return;
    // Skip if same content as the most recent item (avoid consecutive duplicates)
    if (_items.isNotEmpty && _items.first.content == item.content) return;

    _items.insert(0, item);

    // Enforce max count (unpinned only)
    final maxCount = SettingsStore().maxHistoryCount;
    while (_unpinnedCount > maxCount) {
      final idx = _lastUnpinnedIndex();
      if (idx >= 0) _items.removeAt(idx);
    }

    _sort();
    notifyListeners();
    await _persistence.save(_items);
  }

  Future<void> removeItem(String id) async {
    _items.removeWhere((e) => e.id == id);
    notifyListeners();
    await _persistence.save(_items);
  }

  Future<void> togglePin(String id) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    _items[idx] = _items[idx].copyWith(isPinned: !_items[idx].isPinned);
    _sort();
    notifyListeners();
    await _persistence.save(_items);
  }

  Future<void> clearAll() async {
    _items.clear();
    notifyListeners();
    await _persistence.delete();
  }

  // ─── Age-based pruning ────────────────────────────────────────────────────

  /// Remove unpinned items older than [SettingsStore.retainDays] days.
  /// Pinned items are never removed by this rule.
  /// Pass [save]=true (default) to persist after pruning.
  void _pruneByAge({bool save = true}) {
    final retainDays = SettingsStore().retainDays;
    if (retainDays <= 0) return; // 0 means keep forever
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: retainDays));
    final before = _items.length;
    _items.removeWhere((e) => !e.isPinned && e.timestamp.toUtc().isBefore(cutoff));
    if (_items.length != before) {
      notifyListeners();
      if (save) _persistence.save(_items);
    }
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  int get _unpinnedCount => _items.where((e) => !e.isPinned).length;

  int _lastUnpinnedIndex() {
    for (int i = _items.length - 1; i >= 0; i--) {
      if (!_items[i].isPinned) return i;
    }
    return -1;
  }

  void _sort() {
    _items.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      return b.timestamp.compareTo(a.timestamp);
    });
  }
}

