import 'dart:ffi';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

class AutoPasteService {
  /// The window that was focused before the clipboard manager was shown.
  /// Set this before showing our window so we can restore focus on paste.
  static int previousForegroundWindow = 0;

  static void captureCurrentTarget() {
    if (!Platform.isWindows) return;
    previousForegroundWindow = GetForegroundWindow();
  }

  /// Write [text] to clipboard, restore focus to the previous window,
  /// then simulate Ctrl+V so the text lands in the right application.
  static Future<void> paste(String text) async {
    await Clipboard.setData(ClipboardData(text: text));

    if (!Platform.isWindows) {
      return;
    }

    final user32 = DynamicLibrary.open('user32.dll');
    final keybdEvent = user32.lookupFunction<
        Void Function(Uint8, Uint8, Uint32, IntPtr),
        void Function(int, int, int, int)>('keybd_event');

    // Restore focus to the window that was active before we popped up
    if (previousForegroundWindow != 0) {
      SetForegroundWindow(previousForegroundWindow);
      // Small delay to let the OS process the focus switch
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // Simulate Ctrl+V into the now-focused window
    keybdEvent(VK_CONTROL, 0, 0, 0);
    keybdEvent(0x56, 0, 0, 0); // V down
    keybdEvent(0x56, 0, KEYEVENTF_KEYUP, 0); // V up
    keybdEvent(VK_CONTROL, 0, KEYEVENTF_KEYUP, 0);
  }
}
