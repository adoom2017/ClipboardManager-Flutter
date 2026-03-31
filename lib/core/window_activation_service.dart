import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win32;

class WindowActivationService {
  static const _windowClassName = 'FLUTTER_RUNNER_WIN32_WINDOW';
  static const _windowTitle = 'Clipboard Manager';

  static int? _findMainWindow() {
    final title = _windowTitle.toNativeUtf16();
    final className = _windowClassName.toNativeUtf16();
    try {
      final byTitle = win32.FindWindow(nullptr, title);
      if (byTitle != 0) return byTitle;

      final byClass = win32.FindWindow(className, nullptr);
      return byClass == 0 ? null : byClass;
    } finally {
      calloc.free(title);
      calloc.free(className);
    }
  }

  static void _setNoActivateStyle(int hwnd, {required bool enabled}) {
    final current = win32.GetWindowLongPtr(hwnd, win32.GWL_EXSTYLE);
    final next = enabled
        ? (current | win32.WS_EX_NOACTIVATE)
        : (current & ~win32.WS_EX_NOACTIVATE);

    if (next != current) {
      win32.SetWindowLongPtr(hwnd, win32.GWL_EXSTYLE, next);
      win32.SetWindowPos(
        hwnd,
        0,
        0,
        0,
        0,
        0,
        win32.SWP_NOMOVE |
            win32.SWP_NOSIZE |
            win32.SWP_NOZORDER |
            win32.SWP_NOACTIVATE |
            win32.SWP_FRAMECHANGED,
      );
    }
  }

  static Future<void> showInactive() async {
    final hwnd = _findMainWindow();
    if (hwnd == null) return;

    _setNoActivateStyle(hwnd, enabled: true);
    win32.SetWindowPos(
      hwnd,
      win32.HWND_TOPMOST,
      0,
      0,
      0,
      0,
      win32.SWP_NOMOVE |
          win32.SWP_NOSIZE |
          win32.SWP_SHOWWINDOW |
          win32.SWP_NOACTIVATE,
    );
    win32.ShowWindow(hwnd, win32.SW_SHOWNOACTIVATE);
  }

  static Future<void> showInteractive() async {
    final hwnd = _findMainWindow();
    if (hwnd == null) return;

    _setNoActivateStyle(hwnd, enabled: false);
    win32.SetWindowPos(
      hwnd,
      win32.HWND_NOTOPMOST,
      0,
      0,
      0,
      0,
      win32.SWP_NOMOVE |
          win32.SWP_NOSIZE |
          win32.SWP_SHOWWINDOW,
    );
    win32.ShowWindow(hwnd, win32.SW_SHOWNORMAL);
  }
}
