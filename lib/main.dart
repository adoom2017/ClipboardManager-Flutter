import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'core/auto_paste_service.dart';
import 'core/clipboard_monitor.dart';
import 'core/window_activation_service.dart';
import 'storage/clipboard_store.dart';
import 'storage/settings_store.dart';
import 'sync/sync_service.dart';
import 'views/clipboard_list_page.dart';
import 'views/settings_page.dart';
import 'views/sync_page.dart';

final ValueNotifier<int> shellPageIndex = ValueNotifier<int>(0);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Init settings first
  await SettingsStore().init();
  await ClipboardStore().load();

  // Window setup
  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(420, 600),
    minimumSize: Size(420, 600),
    maximumSize: Size(420, 600),
    title: 'Clipboard Manager',
    center: true,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    if (Platform.isWindows) {
      await windowManager.hide();
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
  });

  // Global hotkey: Alt+V
  await hotKeyManager.unregisterAll();
  final hotKey = HotKey(
    key: PhysicalKeyboardKey.keyV,
    modifiers: [HotKeyModifier.alt],
    scope: HotKeyScope.system,
  );
  await hotKeyManager.register(hotKey, keyDownHandler: (_) async {
    if (await windowManager.isVisible()) {
      await windowManager.hide();
    } else {
      // Save the currently focused window before showing the picker so a
      // selection can paste back into the original target.
      AutoPasteService.captureCurrentTarget();
      shellPageIndex.value = 0;
      await WindowActivationService.showInactive();
    }
  });

  // Start clipboard monitor and sync
  ClipboardMonitor.instance.start();
  SyncService.instance.start();

  runApp(const ClipboardManagerApp());
}

class ClipboardManagerApp extends StatelessWidget {
  const ClipboardManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: ClipboardStore()),
        ChangeNotifierProvider.value(value: SettingsStore()),
        ChangeNotifierProvider.value(value: SyncService.instance),
      ],
      child: MaterialApp(
        title: 'Clipboard Manager',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          fontFamily:
              defaultTargetPlatform == TargetPlatform.windows ? 'Segoe UI' : null,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF007AFF),
          ).copyWith(primary: const Color(0xFF007AFF)),
          scaffoldBackgroundColor: const Color(0xFFF2F2F7),
          useMaterial3: true,
        ),
        home: const MainShell(),
      ),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell>
    with WindowListener, TrayListener {
  int _selectedIndex = 0;

  static const _pages = [
    ClipboardListPage(),
    SyncPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    shellPageIndex.addListener(_handleExternalPageChange);
    _initTray();
  }

  @override
  void dispose() {
    shellPageIndex.removeListener(_handleExternalPageChange);
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  void _handleExternalPageChange() {
    if (_selectedIndex == shellPageIndex.value) return;
    setState(() => _selectedIndex = shellPageIndex.value);
  }

  Future<void> _initTray() async {
    if (Platform.isWindows) {
      await trayManager.setIcon('assets/icon.ico');
      await trayManager.setToolTip('Clipboard Manager');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: '显示主窗口'),
        MenuItem.separator(),
        MenuItem(key: 'settings', label: '设置'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ]));
    }
  }

  @override
  void onTrayIconMouseDown() {
    if (Platform.isWindows) {
      trayManager.popUpContextMenu();
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    if (Platform.isWindows) {
      trayManager.popUpContextMenu();
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await WindowActivationService.showInteractive();
        await windowManager.focus();
        break;
      case 'settings':
        shellPageIndex.value = 2;
        await WindowActivationService.showInteractive();
        await windowManager.focus();
        break;
      case 'quit':
        _quit();
        break;
    }
  }

  @override
  void onWindowBlur() {
    if (Platform.isWindows) {
      windowManager.hide();
    }
  }

  @override
  void onWindowClose() async {
    if (Platform.isWindows) {
      await windowManager.hide();
    } else {
      await windowManager.destroy();
    }
  }

  void _quit() async {
    await hotKeyManager.unregisterAll();
    if (Platform.isWindows) {
      await trayManager.destroy();
    }
    ClipboardMonitor.instance.stop();
    await SyncService.instance.stop();
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      body: Column(
        children: [
          const _MacTitleBar(),
          Expanded(child: _pages[_selectedIndex]),
          _MacTabBar(
            selectedIndex: _selectedIndex,
            onTap: (i) {
              shellPageIndex.value = i;
              setState(() => _selectedIndex = i);
            },
          ),
        ],
      ),
    );
  }
}

// ─── macOS-style title bar ────────────────────────────────────────────────

class _MacTitleBar extends StatelessWidget {
  const _MacTitleBar();

  @override
  Widget build(BuildContext context) {
    return DragToMoveArea(
      child: Container(
        height: 44,
        decoration: const BoxDecoration(
          color: Color(0xFFECECEC),
          border: Border(
            bottom: BorderSide(color: Color(0xFFD1D1D6), width: 0.5),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 14),
            _TrafficLight(color: const Color(0xFFFF5F57), onTap: () => windowManager.hide()),
            const SizedBox(width: 8),
            const _TrafficLight(color: Color(0xFFFFBD2E)),
            const SizedBox(width: 8),
            const _TrafficLight(color: Color(0xFF28C840)),
            const Expanded(
              child: Center(
                child: Text(
                  'Clipboard Manager',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1C1C1E),
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 60),
          ],
        ),
      ),
    );
  }
}

class _TrafficLight extends StatefulWidget {
  final Color color;
  final VoidCallback? onTap;
  const _TrafficLight({required this.color, this.onTap});

  @override
  State<_TrafficLight> createState() => _TrafficLightState();
}

class _TrafficLightState extends State<_TrafficLight> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: _hovered ? widget.color : widget.color.withValues(alpha: 0.8),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

// ─── Bottom tab bar ───────────────────────────────────────────────────────

class _MacTabBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onTap;
  const _MacTabBar({required this.selectedIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tabs = [
      (Icons.content_paste_outlined, Icons.content_paste, '历史'),
      (Icons.devices_outlined, Icons.devices, '同步'),
      (Icons.settings_outlined, Icons.settings, '设置'),
    ];
    return Container(
      height: 54,
      decoration: const BoxDecoration(
        color: Color(0xFFF2F2F7),
        border: Border(top: BorderSide(color: Color(0xFFD1D1D6), width: 0.5)),
      ),
      child: Row(
        children: [
          for (int i = 0; i < tabs.length; i++)
            Expanded(
              child: _TabItem(
                outlinedIcon: tabs[i].$1,
                filledIcon: tabs[i].$2,
                label: tabs[i].$3,
                selected: i == selectedIndex,
                onTap: () => onTap(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _TabItem extends StatefulWidget {
  final IconData outlinedIcon;
  final IconData filledIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TabItem({
    required this.outlinedIcon,
    required this.filledIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_TabItem> createState() => _TabItemState();
}

class _TabItemState extends State<_TabItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF007AFF);
    const inactive = Color(0xFF8E8E93);
    final color = widget.selected ? accent : (_hovered ? const Color(0xFF48484A) : inactive);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              widget.selected ? widget.filledIcon : widget.outlinedIcon,
              size: 22,
              color: color,
            ),
            const SizedBox(height: 2),
            Text(
              widget.label,
              style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: widget.selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
