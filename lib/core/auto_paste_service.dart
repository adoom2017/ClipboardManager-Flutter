import 'dart:ffi';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

final _user32 = DynamicLibrary.open('user32.dll');
final _keybdEvent = _user32.lookupFunction<
    Void Function(Uint8, Uint8, Uint32, IntPtr),
    void Function(int, int, int, int)>('keybd_event');

class AutoPasteService {
  /// The window that was focused before the clipboard manager was shown.
  /// Set this before showing our window so we can restore focus on paste.
  static int previousForegroundWindow = 0;

  /// Write [text] to clipboard, restore focus to the previous window,
  /// then simulate Ctrl+V so the text lands in the right application.
  static Future<void> paste(String text) async {
    await Clipboard.setData(ClipboardData(text: text));

    // Restore focus to the window that was active before we popped up
    if (previousForegroundWindow != 0) {
      SetForegroundWindow(previousForegroundWindow);
      // Small delay to let the OS process the focus switch
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // Simulate Ctrl+V into the now-focused window
    _keybdEvent(VK_CONTROL, 0, 0, 0);
    _keybdEvent(0x56, 0, 0, 0); // V down
    _keybdEvent(0x56, 0, KEYEVENTF_KEYUP, 0); // V up
    _keybdEvent(VK_CONTROL, 0, KEYEVENTF_KEYUP, 0);
  }
}
