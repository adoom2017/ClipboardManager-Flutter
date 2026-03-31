import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../view_models/clipboard_list_view_model.dart';
import '../models/clipboard_item.dart';
import 'translation_dialog.dart';

const _kAccent = Color(0xFF007AFF);
const _kTextPrimary = Color(0xFF1C1C1E);
const _kTextSecondary = Color(0xFF8E8E93);
const _kSeparator = Color(0xFFE5E5EA);
const _kHover = Color(0x0A000000);
const _kHoverStrong = Color(0x14000000);

class ClipboardListPage extends StatefulWidget {
  const ClipboardListPage({super.key});

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
      child: _ClipboardListBody(searchCtrl: _searchCtrl),
    );
  }
}

class _ClipboardListBody extends StatelessWidget {
  final TextEditingController searchCtrl;
  const _ClipboardListBody({required this.searchCtrl});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ClipboardListViewModel>();
    final items = vm.filteredItems;

    return Column(
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
                    controller: searchCtrl,
                    style: const TextStyle(fontSize: 13, color: _kTextPrimary),
                    decoration: const InputDecoration(
                      hintText: '搜索',
                      hintStyle: TextStyle(fontSize: 13, color: _kTextSecondary),
                      prefixIcon: Icon(Icons.search, size: 15, color: _kTextSecondary),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                      isDense: true,
                    ),
                    onChanged: vm.setSearch,
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
                      Icon(Icons.content_paste_off,
                          size: 40,
                          color: _kTextSecondary.withOpacity(0.35)),
                      const SizedBox(height: 10),
                      const Text('暂无剪贴板记录',
                          style: TextStyle(
                              color: _kTextSecondary, fontSize: 13)),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (ctx, i) => _ClipboardItemTile(
                    item: items[i],
                    vm: vm,
                    isLast: i == items.length - 1,
                  ),
                ),
        ),
      ],
    );
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
  const _ClipboardItemTile(
      {required this.item, required this.vm, required this.isLast});

  @override
  State<_ClipboardItemTile> createState() => _ClipboardItemTileState();
}

class _ClipboardItemTileState extends State<_ClipboardItemTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isText = item.contentType == ClipboardContentType.text;

    return MouseRegion(
      cursor: isText ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: isText ? () => widget.vm.pasteItem(item) : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          color: _hovered ? _kHover : Colors.transparent,
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
                                    height: 1.35),
                              ),
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  _typeIcon(item.contentType),
                                  const SizedBox(width: 4),
                                  Text(item.relativeTime,
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: _kTextSecondary)),
                                  if (item.sourceApp.isNotEmpty) ...[
                                    const Text('  ·  ',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: _kTextSecondary)),
                                    Flexible(
                                      child: Text(
                                        item.sourceApp,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: _kTextSecondary),
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
                              _ActionIcon(
                                icon: item.isPinned
                                    ? Icons.push_pin
                                    : Icons.push_pin_outlined,
                                color: item.isPinned
                                    ? _kAccent
                                    : _kTextSecondary,
                                tooltip: item.isPinned ? '取消固定' : '固定',
                                onTap: () =>
                                    widget.vm.togglePin(item.id),
                              ),
                              _ActionIcon(
                                icon: Icons.close_rounded,
                                color: _kTextSecondary,
                                tooltip: '删除',
                                onTap: () =>
                                    widget.vm.removeItem(item.id),
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
                      child: Container(
                        width: 3,
                        color: _kAccent,
                      ),
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
    );
  }

  Widget _typeIcon(ClipboardContentType type) {
    final icon = type == ClipboardContentType.image
        ? Icons.image_outlined
        : type == ClipboardContentType.file
            ? Icons.insert_drive_file_outlined
            : Icons.notes_outlined;
    return Icon(icon, size: 11, color: _kTextSecondary);
  }
}

// ─── Shared small widgets ─────────────────────────────────────────────────

class _IconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconBtn({required this.icon, required this.tooltip, required this.onTap});

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
            child: Icon(widget.icon,
                size: 16,
                color: _hovered ? _kTextPrimary : _kTextSecondary),
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
  const _ActionIcon(
      {required this.icon,
      required this.color,
      required this.tooltip,
      required this.onTap});

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
            child: Icon(widget.icon,
                size: 14,
                color: _hovered ? _kTextPrimary : widget.color),
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
  const _MacAlertDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.isDestructive = false,
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
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: _kTextPrimary)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, color: _kTextSecondary)),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _macBtn('取消', onTap: () => Navigator.pop(context, false)),
                const SizedBox(width: 8),
                _macBtn(confirmLabel,
                    onTap: () => Navigator.pop(context, true),
                    isPrimary: true,
                    isDestructive: isDestructive),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _macBtn(String label,
      {required VoidCallback onTap,
      bool isPrimary = false,
      bool isDestructive = false}) {
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
            color: bg, borderRadius: BorderRadius.circular(6)),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: fg)),
      ),
    );
  }
}

