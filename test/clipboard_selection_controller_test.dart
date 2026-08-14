import 'package:clipboard_manager/models/clipboard_item.dart';
import 'package:clipboard_manager/view_models/clipboard_selection_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final items = [_item('first'), _item('second'), _item('third')];

  test('defaults to the first visible clipboard item', () {
    final controller = ClipboardSelectionController();

    expect(controller.selectedIdFor(items), 'first');
  });

  test('moves selection with bounds', () {
    final controller = ClipboardSelectionController();

    expect(controller.move(items, 1), 'second');
    expect(controller.move(items, 1), 'third');
    expect(controller.move(items, 1), 'third');
    expect(controller.move(items, -1), 'second');
  });

  test('preserves selection by id when items reorder', () {
    final controller = ClipboardSelectionController()..select('second');

    expect(controller.selectedIdFor([items[1], items[0], items[2]]), 'second');
  });

  test('falls back to first item when selection disappears', () {
    final controller = ClipboardSelectionController()..select('second');

    expect(controller.selectedIdFor([items[2], items[0]]), 'third');
    expect(controller.selectedIdFor(const []), isNull);
  });
}

ClipboardItem _item(String id) {
  return ClipboardItem(
    id: id,
    contentType: ClipboardContentType.text,
    content: id,
    timestamp: DateTime.utc(2026),
    sourceApp: 'Test',
  );
}
