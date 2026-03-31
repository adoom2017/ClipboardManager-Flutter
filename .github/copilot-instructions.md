# Copilot Instructions

## Build & Run Commands

```powershell
flutter pub get                          # Install / update dependencies
flutter build windows --release          # Production build → build\windows\x64\runner\Release\
flutter run -d windows                   # Debug run (shows window immediately, skips tray-hide startup)
flutter analyze                          # Lint (flutter_lints/flutter.yaml ruleset)
flutter test                             # All tests
flutter test test/widget_test.dart       # Single test file
```

> The app starts hidden to the system tray. Use **Alt+V** to show it during a debug run.

## Architecture

The app is a Windows-only Flutter desktop app. It runs as a **system-tray utility** — no taskbar presence by default — and pops up on a global hotkey (Alt+V).

### Data flow

```
ClipboardMonitor (500ms poll)
    ↓ addItem()
ClipboardStore (singleton ChangeNotifier, in-memory list)
    ↓ save()
PersistenceController → %APPDATA%\ClipboardManager\clipboard_history.json
```

`ClipboardStore` is exposed to the widget tree via `ChangeNotifierProvider.value` in `main.dart`. Views consume it through `ClipboardListViewModel`, which is a thin wrapper that adds search-filter logic and delegates paste/pin/delete to the store.

### Layers

| Layer | Package path | Responsibility |
|---|---|---|
| Models | `lib/models/` | `ClipboardItem` with manual JSON (`toJson`/`fromJson`), no codegen |
| Storage | `lib/storage/` | `ClipboardStore` (state), `PersistenceController` (file I/O), `SettingsStore` (SharedPreferences + registry) |
| Core | `lib/core/` | `ClipboardMonitor` (polling), `AutoPasteService` (Win32 focus + keybd_event), `PrivacyGuard` (keyword filter) |
| Sync | `lib/sync/` | TCP pairing + AES-GCM sync; `SyncDiscovery` (mDNS), `SyncCrypto` (HKDF-SHA256), `SyncConnection` (4-byte big-endian framing), `SyncService` (orchestration) |
| Views | `lib/views/` | Three pages (History, Sync, Settings) in macOS visual style |
| ViewModels | `lib/view_models/` | One VM per page (currently only `ClipboardListViewModel`) |
| Shell | `lib/main.dart` | Window/tray/hotkey init, `MainShell` scaffold with custom `_MacTitleBar` and `_MacTabBar` |

### Singleton pattern

`ClipboardStore`, `SettingsStore`, and `SyncService` are **factory singletons** — `ClipboardStore()` always returns the same instance. Never construct them directly for dependency injection; use `ChangeNotifierProvider.value`.

## Key Conventions

### Win32 FFI
- Import `package:win32/win32.dart` **aliased as `win32`** in files that also use Flutter types to avoid name collisions (e.g., `import 'package:win32/win32.dart' as win32;` in `main.dart`).
- `keybd_event` is accessed via `DynamicLibrary.open('user32.dll').lookupFunction(...)` — **not** a top-level function in win32 5.x.
- All `calloc`-allocated FFI memory must be freed manually with `calloc.free(ptr)`.

### Focus restoration for auto-paste
`AutoPasteService.previousForegroundWindow` must be set **before** calling `windowManager.show()` in the Alt+V hotkey handler. The paste flow is:
1. `windowManager.hide()`
2. `SetForegroundWindow(savedHwnd)`
3. `await Future.delayed(100ms)`
4. Simulate Ctrl+V via `keybd_event`

### Window lifecycle
- Window starts **hidden** (`waitUntilReadyToShow` calls `hide()`).
- `onWindowBlur()` and `onWindowClose()` both call `windowManager.hide()` — the window never truly closes except via "退出" in the tray menu.
- The title bar uses `TitleBarStyle.hidden` with a custom `DragToMoveArea` widget.

### UI design tokens (macOS style)
All pages use these shared constants (defined locally per file):

| Token | Value |
|---|---|
| Accent | `#007AFF` |
| Background | `#F2F2F7` |
| Surface (cards) | `#FFFFFF` |
| Text primary | `#1C1C1E` |
| Text secondary | `#8E8E93` |
| Separator | `#E5E5EA` |
| Success/on | `#34C759` |
| Destructive | `#FF3B30` |

Use `CupertinoSwitch` for toggles in settings. Interactive widgets use `MouseRegion` + `GestureDetector` with `AnimatedContainer` hover states (100ms duration) — avoid `InkWell`.

### Sync wire format
Encrypted payload = `base64(nonce[12] + ciphertext + GCM_tag[16])`. HKDF salt = `"<id1>:<id2>:<pin>"` where IDs are lexicographically sorted. This must stay compatible with the macOS ClipboardManager counterpart.

### Persistence paths
- Clipboard history: `%APPDATA%\ClipboardManager\clipboard_history.json`
- Settings: SharedPreferences (Flutter's default Windows location)
- Startup registry key: `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\ClipboardManager`

### Icon files
- `assets/icon.ico` — tray icon (referenced by string path in `tray_manager.setIcon()`)
- `windows/runner/resources/app_icon.ico` — exe/taskbar icon (compiled into the runner)
- Both must be updated together when changing the icon; rebuild required.
