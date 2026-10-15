import 'package:clipboard_manager/sync/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const existing = '00000000-0000-0000-0000-000000000001';
  const fresh = 'AAAAAAAA-0000-0000-0000-000000000002';
  final now = DateTime.utc(2026, 1, 1);

  Map<String, dynamic> raw(
    String id,
    String content, {
    String sourceApp = 'Safari',
    bool isPinned = false,
  }) => {
    'id': id,
    'content': content,
    'timestamp': 0.0,
    'sourceApp': sourceApp,
    'isPinned': isPinned,
  };

  test('dedupes by UUID and normalizes received fields', () {
    final items = SyncService.receivedItems(
      [
        raw(fresh, 'new', isPinned: true),
        raw(existing.toUpperCase(), 'already stored'),
        raw(fresh.toLowerCase(), 'replayed'),
        raw(
          '00000000-0000-0000-0000-000000000003',
          'echo',
          sourceApp: '📡 Notepad',
        ),
      ],
      exists: (id) => id == existing,
      now: now,
    );

    expect(items, isNotNull);
    expect(items!.map((item) => item.content), ['new', 'echo']);
    expect(items[0].id, fresh.toLowerCase());
    expect(items[0].isPinned, isFalse);
    expect(items[0].timestamp, now);
    expect(items[1].timestamp.isBefore(now), isTrue);
    expect(items[0].sourceApp, '📡 Safari');
    expect(items[1].sourceApp, '📡 Notepad');
  });

  test('rejects the whole batch when an entry is malformed', () {
    expect(
      SyncService.receivedItems(
        [raw(fresh, 'ok'), raw('not-a-uuid', 'bad')],
        exists: (_) => false,
        now: now,
      ),
      isNull,
    );
  });
}
