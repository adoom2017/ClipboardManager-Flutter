import 'dart:async';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';
import 'package:uuid/uuid.dart';
import '../models/clipboard_item.dart';
import '../storage/clipboard_store.dart';
import 'privacy_guard.dart';

/// Monitors clipboard using periodic polling via Flutter's Clipboard API.
class ClipboardMonitor {
  static final ClipboardMonitor instance = ClipboardMonitor._();
  ClipboardMonitor._();

  Timer? _timer;
  String? _lastText;
  bool _running = false;
  final StreamController<ClipboardItem> _newItems =
      StreamController<ClipboardItem>.broadcast();

  Stream<ClipboardItem> get newItems => _newItems.stream;

  void start() {
    if (_running) return;
    _running = true;
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _check());
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _check() async {
    if (!_running) return;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null || text.isEmpty || text == _lastText) return;
      _lastText = text;

      final sourceApp = _getForegroundAppName();

      final item = ClipboardItem(
        id: const Uuid().v4(),
        contentType: ClipboardContentType.text,
        content: text,
        timestamp: DateTime.now().toUtc(),
        sourceApp: sourceApp,
      );

      if (!PrivacyGuard.isAllowed(item)) return;
      await ClipboardStore().addItem(item);
      _newItems.add(item);
    } catch (_) {}
  }

  String _getForegroundAppName() {
    try {
      final hWnd = GetForegroundWindow();
      if (hWnd == 0) return 'Unknown';

      final pidPtr = calloc<Uint32>();
      GetWindowThreadProcessId(hWnd, pidPtr);
      final pid = pidPtr.value;
      calloc.free(pidPtr);

      final hProcess = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
      if (hProcess == 0) return 'Unknown';

      final nameBuf = wsalloc(MAX_PATH);
      final sizePtr = calloc<Uint32>()..value = MAX_PATH;
      QueryFullProcessImageName(hProcess, 0, nameBuf, sizePtr);
      CloseHandle(hProcess);

      final fullPath = nameBuf.toDartString();
      calloc.free(nameBuf);
      calloc.free(sizePtr);

      final parts = fullPath.replaceAll('\\', '/').split('/');
      return parts.isNotEmpty ? parts.last : 'Unknown';
    } catch (_) {
      return 'Unknown';
    }
  }
}
