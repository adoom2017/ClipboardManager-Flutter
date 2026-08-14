import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../view_models/clipboard_list_view_model.dart';
import '../view_models/clipboard_selection_controller.dart';
import '../models/clipboard_item.dart';
import '../sync/sync_service.dart';
import 'translation_dialog.dart';

const _kAccent = Color(0xFF007AFF);
const _kTextPrimary = Color(0xFF1C1C1E);
const _kTextSecondary = Color(0xFF8E8E93);
const _kSeparator = Color(0xFFE5E5EA);
const _kHover = Color(0x0A000000);
const _kHoverStrong = Color(0x14000000);

class ClipboardListPage extends StatefulWidget {
  final ValueListenable<int>? focusRequest;

  const ClipboardListPage({super.key, this.focusRequest});

  @override
  State<ClipboardListPage> createState() => _ClipboardListPageState();
}

class _ClipboardListPageState extends State<ClipboardListPage> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ClipboardListViewModel(),
      child: _ClipboardListBody(
        searchCtrl: _searchCtrl,
        focusRequest: widget.focusRequest,
      ),
    );
  }
}

class _ClipboardListBody extends StatefulWidget {
  final TextEditingController searchCtrl;
  final ValueListenable<int>? focusRequest;

  const _ClipboardListBody({
    required this.searchCtrl,
    required this.focusRequest,
  });

  @override
  State<_ClipboardListBody> createState() => _ClipboardListBodyState();
}

class _ClipboardListBodyState extends State<_ClipboardListBody> {
  final _focusNode = FocusNode(debugLabel: 'clipboard-list');
  final _selection = ClipboardSelectionController();
  final Map<String, GlobalKey> _itemKeys = {};

  @override
  void initState() {
    super.initState();
    widget.focusRequest?.addListener(_requestFocus);
  }

  @override
  void didUpdateWidget(covariant _ClipboardListBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusRequest != widget.focusRequest) {
      oldWidget.focusRequest?.removeListener(_requestFocus);
      widget.focusRequest?.addListener(_requestFocus);
    }
  }

  @override
  void dispose() {
    widget.focusRequest?.removeListener(_requestFocus);
    _focusNode.dispose();
    super.dispose();
  }

  void _requestFocus() {
    if (mounted) _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ClipboardListViewModel>();
    final items = vm.filteredItems;

    final selectedId = _selection.selectedIdFor(items);

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) => _handleKeyEvent(event, vm, items),
      child: Column(
        children: [
          // Search bar row
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 30,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE5E5EA),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: TextField(
                      controller: widget.searchCtrl,
                      style: const TextStyle(
                        fontSize: 13,
                        color: _kTextPrimary,
                      ),
                      decoration: const InputDecoration(
                        hintText: '搜索',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: _kTextSecondary,
                        ),
                        prefixIcon: Icon(
                          Icons.search,
                          size: 15,
                          color: _kTextSecondary,
                        ),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 8),
                        isDense: true,
                      ),
                      onChanged: (value) {
                        _selection.reset();
                        vm.setSearch(value);
                      },
                      onSubmitted: (_) => _pasteSelected(vm, vm.filteredItems),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _IconBtn(
                  icon: Icons.delete_sweep_outlined,
                  tooltip: '清空历史',
                  onTap: () => _confirmClear(context, vm),
                ),
              ],
            ),
          ),
          // Count
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 0, 13, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${items.length} 条记录',
                style: const TextStyle(fontSize: 11, color: _kTextSecondary),
              ),
            ),
          ),
          // List
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.content_paste_off,
                          size: 40,
                          color: _kTextSecondary.withValues(alpha: 0.35),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          '暂无剪贴板记录',
                          style: TextStyle(
                            color: _kTextSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (ctx, i) {
                      final item = items[i];
                      final itemKey = _itemKeys.putIfAbsent(
                        item.id,
                        GlobalKey.new,
                      );
                      return _ClipboardItemTile(
                        key: itemKey,
                        item: item,
                        vm: vm,
                        isLast: i == items.length - 1,
                        isSelected: item.id == selectedId,
                        onSelected: () {
                          _selection.select(item.id);
                          _focusNode.requestFocus();
                          setState(() {});
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  KeyEventResult _handleKeyEvent(
    KeyEvent event,
    ClipboardListViewModel vm,
    List<ClipboardItem> items,
  ) {
    final isPress = event is KeyDownEvent || event is KeyRepeatEvent;
    if (!isPress) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveSelection(items, 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveSelection(items, -1);
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      _pasteSelected(vm, items);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _moveSelection(List<ClipboardItem> items, int offset) {
    final selectedId = _selection.move(items, offset);
    if (selectedId == null) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final itemContext = _itemKeys[selectedId]?.currentContext;
      if (!mounted || itemContext == null) return;
      Scrollable.ensureVisible(
        itemContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    });
  }

  void _pasteSelected(ClipboardListViewModel vm, List<ClipboardItem> items) {
    final item = _selection.selectedItemFor(items);
    if (item == null || item.contentType != ClipboardContentType.text) return;
    unawaited(vm.pasteItem(item));
  }

  void _confirmClear(BuildContext context, ClipboardListViewModel vm) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _MacAlertDialog(
        title: '清空历史',
        message: '确认删除所有剪贴板历史？\n此操作无法撤销。',
        confirmLabel: '清空',
        isDestructive: true,
      ),
    );
    if (ok == true) vm.clearAll();
  }
}

// ─── Clipboard item tile ──────────────────────────────────────────────────

class _ClipboardItemTile extends StatefulWidget {
  final ClipboardItem item;
  final ClipboardListViewModel vm;
  final bool isLast;
  final bool isSelected;
  final VoidCallback onSelected;
  const _ClipboardItemTile({
    super.key,
    required this.item,
    required this.vm,
    required this.isLast,
    required this.isSelected,
    required this.onSelected,
  });

  @override
  State<_ClipboardItemTile> createState() => _ClipboardItemTileState();
}

class _ClipboardItemTileState extends State<_ClipboardItemTile> {
  bool _hovered = false;
  bool _pointerInTile = false;
  bool _pointerInDetail = false;
  Timer? _previewTimer;
  Timer? _hideTimer;
  OverlayEntry? _detailOverlay;

  @override
  void didUpdateWidget(covariant _ClipboardItemTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _removeDetailOverlay();
    }
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    _hideTimer?.cancel();
    _detailOverlay?.remove();
    _detailOverlay = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isText = item.contentType == ClipboardContentType.text;

    return Semantics(
      selected: widget.isSelected,
      focusable: true,
      child: MouseRegion(
        cursor: isText ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => _handleTileHover(true),
        onExit: (_) => _handleTileHover(false),
        child: GestureDetector(
          onTap: () {
            widget.onSelected();
            if (isText) unawaited(widget.vm.pasteItem(item));
          },
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? _kAccent.withValues(alpha: 0.10)
                  : _hovered
                  ? _kHover
                  : Colors.transparent,
              border: Border.all(
                color: widget.isSelected
                    ? _kAccent.withValues(alpha: 0.65)
                    : Colors.transparent,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  children: [
                    // Content
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.contentPreview,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: _kTextPrimary,
                                    height: 1.35,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    _typeIcon(item.contentType),
                                    const SizedBox(width: 4),
                                    Text(
                                      item.relativeTime,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: _kTextSecondary,
                                      ),
                                    ),
                                    if (item.sourceApp.isNotEmpty) ...[
                                      const Text(
                                        '  ·  ',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: _kTextSecondary,
                                        ),
                                      ),
                                      Flexible(
                                        child: Text(
                                          item.sourceApp,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: _kTextSecondary,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          // Action buttons — fade in on hover
                          AnimatedOpacity(
                            opacity: _hovered ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 120),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isText)
                                  _ActionIcon(
                                    icon: Icons.translate,
                                    color: _kTextSecondary,
                                    tooltip: '翻译',
                                    onTap: () => showDialog(
                                      context: context,
                                      builder: (_) =>
                                          TranslationDialog(text: item.content),
                                    ),
                                  ),
                                if (isText)
                                  _ActionIcon(
                                    icon: Icons.sync_rounded,
                                    color: _kTextSecondary,
                                    tooltip: '同步',
                                    onTap: () => _handleSync(item),
                                  ),
                                _ActionIcon(
                                  icon: item.isPinned
                                      ? Icons.push_pin
                                      : Icons.push_pin_outlined,
                                  color: item.isPinned
                                      ? _kAccent
                                      : _kTextSecondary,
                                  tooltip: item.isPinned ? '取消固定' : '固定',
                                  onTap: () => widget.vm.togglePin(item.id),
                                ),
                                _ActionIcon(
                                  icon: Icons.close_rounded,
                                  color: _kTextSecondary,
                                  tooltip: '删除',
                                  onTap: () => widget.vm.removeItem(item.id),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Left blue strip for pinned items
                    if (item.isPinned)
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        child: Container(width: 3, color: _kAccent),
                      ),
                  ],
                ),
                if (!widget.isLast)
                  const Divider(
                    height: 1,
                    thickness: 0.5,
                    color: _kSeparator,
                    indent: 14,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _handleTileHover(bool hovering) {
    _pointerInTile = hovering;
    _hideTimer?.cancel();
    _previewTimer?.cancel();
    if (mounted) setState(() => _hovered = hovering);

    if (hovering) {
      _previewTimer = Timer(
        const Duration(milliseconds: 350),
        _showDetailOverlay,
      );
    } else {
      _scheduleDetailHide();
    }
  }

  void _showDetailOverlay() {
    if (!mounted || !_pointerInTile || _detailOverlay != null) return;
    _detailOverlay = OverlayEntry(
      builder: (overlayContext) => Positioned(
        left: 16,
        right: 16,
        top: 92,
        child: MouseRegion(
          onEnter: (_) {
            _pointerInDetail = true;
            _hideTimer?.cancel();
          },
          onExit: (_) {
            _pointerInDetail = false;
            _scheduleDetailHide();
          },
          child: _ClipboardDetailCard(
            item: widget.item,
            onClose: _removeDetailOverlay,
          ),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_detailOverlay!);
  }

  void _scheduleDetailHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 150), () {
      if (!_pointerInTile && !_pointerInDetail) {
        _removeDetailOverlay();
      }
    });
  }

  void _removeDetailOverlay() {
    _previewTimer?.cancel();
    _hideTimer?.cancel();
    _detailOverlay?.remove();
    _detailOverlay = null;
    _pointerInDetail = false;
  }

  Widget _typeIcon(ClipboardContentType type) {
    final icon = type == ClipboardContentType.image
        ? Icons.image_outlined
        : type == ClipboardContentType.file
        ? Icons.insert_drive_file_outlined
        : Icons.notes_outlined;
    return Icon(icon, size: 11, color: _kTextSecondary);
  }

  Future<void> _handleSync(ClipboardItem item) async {
    final peers = SyncService.instance.discoveredPeers;
    if (peers.isEmpty) {
      if (!mounted) return;
      await showDialog<bool>(
        context: context,
        builder: (ctx) => const _MacAlertDialog(
          title: '未发现服务',
          message: '当前未发现可同步的局域网设备。',
          confirmLabel: '确定',
          showCancel: false,
        ),
      );
      return;
    }

    if (peers.length == 1) {
      await _sendItemToPeer(peers.first, item);
      return;
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _PeerPickerDialog(
        peers: peers,
        onSelected: (peer) async {
          Navigator.pop(ctx);
          await _sendItemToPeer(peer, item);
        },
      ),
    );
  }

  Future<void> _sendItemToPeer(dynamic peer, ClipboardItem item) async {
    try {
      await SyncService.instance.sendItemToPeer(item, peer as dynamic);
    } catch (error) {
      if (!mounted) return;
      await showDialog<bool>(
        context: context,
        builder: (ctx) => _MacAlertDialog(
          title: '同步失败',
          message: '无法同步到 ${peer.displayName}。\n$error',
          confirmLabel: '确定',
          showCancel: false,
        ),
      );
    }
  }
}

class _ClipboardDetailCard extends StatelessWidget {
  final ClipboardItem item;
  final VoidCallback onClose;

  const _ClipboardDetailCard({required this.item, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: Colors.black.withValues(alpha: 0.10),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 330),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '完整内容',
                      style: TextStyle(
                        color: _kTextPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    onPressed: onClose,
                    icon: const Icon(Icons.close, color: _kTextSecondary),
                  ),
                ],
              ),
              Text(
                '${item.sourceApp}  ·  ${item.relativeTime}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: _kTextSecondary),
              ),
              const SizedBox(height: 8),
              const Divider(height: 1, color: _kSeparator),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(
                    _detailText,
                    style: const TextStyle(
                      color: _kTextPrimary,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _detailText {
    if (item.contentType == ClipboardContentType.file &&
        item.fileUrls?.isNotEmpty == true) {
      return item.fileUrls!.join('\n');
    }
    return item.content;
  }
}

// ─── Shared small widgets ─────────────────────────────────────────────────

class _IconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: widget.tooltip,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: _hovered ? _kHoverStrong : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              widget.icon,
              size: 16,
              color: _hovered ? _kTextPrimary : _kTextSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionIcon extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  const _ActionIcon({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_ActionIcon> createState() => _ActionIconState();
}

class _ActionIconState extends State<_ActionIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: widget.tooltip,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: _hovered ? _kHoverStrong : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(
              widget.icon,
              size: 14,
              color: _hovered ? _kTextPrimary : widget.color,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── macOS-style alert dialog ─────────────────────────────────────────────

class _MacAlertDialog extends StatelessWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final bool isDestructive;
  final bool showCancel;
  const _MacAlertDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.isDestructive = false,
    this.showCancel = true,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      backgroundColor: Colors.white,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: _kTextPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: _kTextSecondary),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (showCancel) ...[
                  _macBtn('取消', onTap: () => Navigator.pop(context, false)),
                  const SizedBox(width: 8),
                ],
                _macBtn(
                  confirmLabel,
                  onTap: () => Navigator.pop(context, true),
                  isPrimary: true,
                  isDestructive: isDestructive,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _macBtn(
    String label, {
    required VoidCallback onTap,
    bool isPrimary = false,
    bool isDestructive = false,
  }) {
    final bg = isPrimary && isDestructive
        ? const Color(0xFFFF3B30)
        : isPrimary
        ? _kAccent
        : const Color(0xFFE5E5EA);
    final fg = isPrimary ? Colors.white : _kTextPrimary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: fg,
          ),
        ),
      ),
    );
  }
}

class _PeerPickerDialog extends StatelessWidget {
  final List<dynamic> peers;
  final Future<void> Function(dynamic peer) onSelected;

  const _PeerPickerDialog({required this.peers, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      backgroundColor: Colors.white,
      child: SizedBox(
        width: 320,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '选择同步目标',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: _kTextPrimary,
                ),
              ),
              const SizedBox(height: 12),
              for (int i = 0; i < peers.length; i++) ...[
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onSelected(peers[i]),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.devices, size: 18, color: _kAccent),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                peers[i].displayName,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: _kTextPrimary,
                                ),
                              ),
                              Text(
                                '${peers[i].host}:${peers[i].port}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: _kTextSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (i < peers.length - 1)
                  const Divider(height: 1, thickness: 0.5, color: _kSeparator),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE5E5EA),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      '取消',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: _kTextPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
