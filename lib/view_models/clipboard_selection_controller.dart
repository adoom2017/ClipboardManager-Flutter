import '../models/clipboard_item.dart';

class ClipboardSelectionController {
  String? _selectedItemId;

  String? selectedIdFor(List<ClipboardItem> items) {
    return selectedItemFor(items)?.id;
  }

  ClipboardItem? selectedItemFor(List<ClipboardItem> items) {
    if (items.isEmpty) return null;
    final selectedIndex = items.indexWhere(
      (item) => item.id == _selectedItemId,
    );
    return selectedIndex >= 0 ? items[selectedIndex] : items.first;
  }

  String? move(List<ClipboardItem> items, int offset) {
    if (items.isEmpty) {
      _selectedItemId = null;
      return null;
    }

    final current = selectedItemFor(items)!;
    final currentIndex = items.indexWhere((item) => item.id == current.id);
    final nextIndex = (currentIndex + offset).clamp(0, items.length - 1);
    _selectedItemId = items[nextIndex].id;
    return _selectedItemId;
  }

  void select(String itemId) {
    _selectedItemId = itemId;
  }

  void reset() {
    _selectedItemId = null;
  }
}
