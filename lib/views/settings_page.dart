import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../storage/settings_store.dart';
import '../storage/clipboard_store.dart';

const _kAccent = Color(0xFF007AFF);
const _kTextPrimary = Color(0xFF1C1C1E);
const _kTextSecondary = Color(0xFF8E8E93);
const _kSeparator = Color(0xFFE5E5EA);
const _kSurface = Color(0xFFFFFFFF);

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: SettingsStore(),
      child: const _SettingsBody(),
    );
  }
}

class _SettingsBody extends StatelessWidget {
  const _SettingsBody();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 24),
      children: [
        _section('通用', [
          _row(
            label: '最大历史数量',
            trailing: _NumberField(
              value: s.maxHistoryCount,
              onChanged: s.setMaxHistoryCount,
            ),
          ),
          _row(
            label: '保留天数',
            trailing: _NumberField(
              value: s.retainDays,
              onChanged: s.setRetainDays,
            ),
          ),
          _row(
            label: '开机自动启动',
            trailing: CupertinoSwitch(
              value: s.launchAtStartup,
              onChanged: s.setLaunchAtStartup,
              activeTrackColor: const Color(0xFF34C759),
            ),
          ),
        ]),
        const SizedBox(height: 20),
        _section('隐私', [
          _row(
            label: '隐私保护',
            subtitle: '过滤包含密码等敏感词的内容',
            trailing: CupertinoSwitch(
              value: s.privacyGuardEnabled,
              onChanged: s.setPrivacyGuardEnabled,
              activeTrackColor: const Color(0xFF34C759),
            ),
          ),
        ]),
        const SizedBox(height: 20),
        _section('数据', [
          _DestructiveRow(
            label: '清空所有历史',
            onTap: (ctx) => _confirmClear(ctx),
          ),
        ]),
        const SizedBox(height: 20),
        _section('翻译', [
          _row(
            label: 'API 地址',
            subtitle: 'Gemini 填写 https://generativelanguage.googleapis.com',
            trailing: const SizedBox.shrink(),
          ),
          _fullRow(
            child: _SettingsTextField(
              value: s.translationApiUrl,
              hint: 'https://api.openai.com/v1',
              onChanged: s.setTranslationApiUrl,
            ),
          ),
          _row(
            label: 'API Key',
            trailing: const SizedBox.shrink(),
          ),
          _fullRow(
            child: _PasswordField(
              value: s.translationApiKey,
              hint: 'sk-…',
              onChanged: s.setTranslationApiKey,
            ),
          ),
          _row(
            label: '模型',
            trailing: const SizedBox.shrink(),
          ),
          _fullRow(
            child: _SettingsTextField(
              value: s.translationModel,
              hint: 'gpt-4o-mini',
              onChanged: s.setTranslationModel,
            ),
          ),
        ]),
      ],
    );
  }

  Widget _section(String title, List<Widget> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: _kTextSecondary,
              letterSpacing: 0.4,
            ),
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: _kSurface,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Column(
            children: [
              for (int i = 0; i < rows.length; i++) ...[
                rows[i],
                if (i < rows.length - 1)
                  const Divider(
                    height: 1,
                    thickness: 0.5,
                    indent: 16,
                    color: _kSeparator,
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _row({required String label, String? subtitle, required Widget trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style:
                        const TextStyle(fontSize: 14, color: _kTextPrimary)),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle,
                        style: const TextStyle(
                            fontSize: 11, color: _kTextSecondary)),
                  ),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }

  Widget _fullRow({required Widget child}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: child,
    );
  }

  void _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('清空历史',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: _kTextPrimary)),
              const SizedBox(height: 8),
              const Text('确认删除所有剪贴板历史？\n此操作无法撤销。',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 12, color: _kTextSecondary)),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _btn('取消',
                      bg: const Color(0xFFE5E5EA),
                      fg: _kTextPrimary,
                      onTap: () => Navigator.pop(ctx, false)),
                  const SizedBox(width: 8),
                  _btn('清空',
                      bg: const Color(0xFFFF3B30),
                      fg: Colors.white,
                      onTap: () => Navigator.pop(ctx, true)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok == true) await ClipboardStore().clearAll();
  }

  Widget _btn(String label,
      {required Color bg,
      required Color fg,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: fg)),
      ),
    );
  }
}

// ─── Number input field ───────────────────────────────────────────────────

class _NumberField extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const _NumberField({required this.value, required this.onChanged});

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value.toString());
  }

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value &&
        _ctrl.text != widget.value.toString()) {
      _ctrl.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 60,
      child: TextField(
        controller: _ctrl,
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        style:
            const TextStyle(fontSize: 13, color: _kTextPrimary),
        decoration: InputDecoration(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          filled: true,
          fillColor: const Color(0xFFF2F2F7),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: _kSeparator),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: _kSeparator),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: _kAccent),
          ),
        ),
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n != null && n > 0) widget.onChanged(n);
        },
      ),
    );
  }
}

// ─── Destructive action row ───────────────────────────────────────────────

class _DestructiveRow extends StatefulWidget {
  final String label;
  final void Function(BuildContext) onTap;
  const _DestructiveRow({required this.label, required this.onTap});

  @override
  State<_DestructiveRow> createState() => _DestructiveRowState();
}

class _DestructiveRowState extends State<_DestructiveRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFFF3B30);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => widget.onTap(context),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          color: _hovered
              ? const Color(0xFFFFEBEB)
              : Colors.transparent,
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.delete_outline,
                  size: 16, color: red),
              const SizedBox(width: 8),
              Text(widget.label,
                  style:
                      const TextStyle(fontSize: 14, color: red)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Settings text field ──────────────────────────────────────────────────

class _SettingsTextField extends StatefulWidget {
  final String value;
  final String hint;
  final ValueChanged<String> onChanged;
  const _SettingsTextField({required this.value, required this.hint, required this.onChanged});

  @override
  State<_SettingsTextField> createState() => _SettingsTextFieldState();
}

class _SettingsTextFieldState extends State<_SettingsTextField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(_SettingsTextField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _ctrl.text != widget.value) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      style: const TextStyle(fontSize: 13, color: _kTextPrimary),
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: const TextStyle(fontSize: 13, color: _kTextSecondary),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        filled: true,
        fillColor: const Color(0xFFF2F2F7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: _kSeparator),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: _kSeparator),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: _kAccent),
        ),
      ),
      onChanged: widget.onChanged,
    );
  }
}

// ─── Password field ───────────────────────────────────────────────────────

class _PasswordField extends StatefulWidget {
  final String value;
  final String hint;
  final ValueChanged<String> onChanged;
  const _PasswordField({required this.value, required this.hint, required this.onChanged});

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  late final TextEditingController _ctrl;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(_PasswordField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _ctrl.text != widget.value) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      obscureText: _obscure,
      style: const TextStyle(fontSize: 13, color: _kTextPrimary),
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: const TextStyle(fontSize: 13, color: _kTextSecondary),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        filled: true,
        fillColor: const Color(0xFFF2F2F7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: _kSeparator),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: _kSeparator),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: _kAccent),
        ),
        suffixIcon: GestureDetector(
          onTap: () => setState(() => _obscure = !_obscure),
          child: Icon(
            _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            size: 16,
            color: _kTextSecondary,
          ),
        ),
      ),
      onChanged: widget.onChanged,
    );
  }
}
