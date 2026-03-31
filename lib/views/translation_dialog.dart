import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/translation_service.dart';
import '../storage/settings_store.dart';

const _kAccent = Color(0xFF007AFF);
const _kTextPrimary = Color(0xFF1C1C1E);
const _kTextSecondary = Color(0xFF8E8E93);
const _kSurface = Color(0xFFFFFFFF);
const _kBg = Color(0xFFF2F2F7);

/// macOS-style translation popup.
///
/// Usage:
/// ```dart
/// showDialog(
///   context: context,
///   builder: (_) => TranslationDialog(text: item.content),
/// );
/// ```
class TranslationDialog extends StatefulWidget {
  final String text;
  const TranslationDialog({super.key, required this.text});

  @override
  State<TranslationDialog> createState() => _TranslationDialogState();
}

class _TranslationDialogState extends State<TranslationDialog> {
  _Phase _phase = _Phase.loading;
  String _result = '';
  String _error = '';
  bool _copied = false;

  late final String _directionLabel;

  @override
  void initState() {
    super.initState();
    _directionLabel = TranslationService.directionLabel(widget.text);
    _translate();
  }

  Future<void> _translate() async {
    setState(() {
      _phase = _Phase.loading;
      _error = '';
      _copied = false;
    });

    final s = SettingsStore();
    try {
      final result = await TranslationService.translate(
        widget.text,
        apiUrl: s.translationApiUrl,
        apiKey: s.translationApiKey,
        model: s.translationModel,
      );
      if (mounted) setState(() { _phase = _Phase.done; _result = result; });
    } catch (e) {
      if (mounted) setState(() { _phase = _Phase.error; _error = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: _result));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        width: 380,
        constraints: const BoxConstraints(maxHeight: 420),
        decoration: BoxDecoration(
          color: _kSurface,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.18),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            const Divider(height: 1, thickness: 0.5, color: Color(0xFFE5E5EA)),
            Flexible(child: _buildBody()),
            const Divider(height: 1, thickness: 0.5, color: Color(0xFFE5E5EA)),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      child: Row(
        children: [
          const Icon(Icons.translate, size: 16, color: _kAccent),
          const SizedBox(width: 8),
          Text(
            _directionLabel,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: _kTextPrimary,
            ),
          ),
          const Spacer(),
          _CloseButton(onTap: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _kAccent,
                ),
              ),
              SizedBox(height: 12),
              Text('翻译中…', style: TextStyle(fontSize: 12, color: _kTextSecondary)),
            ],
          ),
        );

      case _Phase.error:
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Color(0xFFFF3B30), size: 28),
              const SizedBox(height: 10),
              Text(
                _error,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Color(0xFFFF3B30)),
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: _translate,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    color: _kAccent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('重试',
                      style: TextStyle(fontSize: 12, color: Colors.white)),
                ),
              ),
            ],
          ),
        );

      case _Phase.done:
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: SelectableText(
            _result,
            style: const TextStyle(
              fontSize: 14,
              color: _kTextPrimary,
              height: 1.5,
            ),
          ),
        );
    }
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          // Original preview
          Expanded(
            child: Text(
              widget.text.length > 40
                  ? '${widget.text.substring(0, 40)}…'
                  : widget.text,
              style: const TextStyle(fontSize: 11, color: _kTextSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_phase == _Phase.done) ...[
            const SizedBox(width: 8),
            _CopyButton(copied: _copied, onTap: _copy),
          ],
        ],
      ),
    );
  }
}

// ─── Small reusable widgets ───────────────────────────────────────────────

enum _Phase { loading, done, error }

class _CloseButton extends StatefulWidget {
  final VoidCallback onTap;
  const _CloseButton({required this.onTap});

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFFE5E5EA) : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Icon(Icons.close_rounded,
              size: 15, color: _hovered ? _kTextPrimary : _kTextSecondary),
        ),
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  final bool copied;
  final VoidCallback onTap;
  const _CopyButton({required this.copied, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: copied ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: copied ? const Color(0xFF34C759) : _kAccent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(copied ? Icons.check : Icons.copy_outlined,
                size: 12, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              copied ? '已复制' : '复制',
              style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
