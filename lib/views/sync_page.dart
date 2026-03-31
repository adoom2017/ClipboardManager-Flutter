import 'package:flutter/material.dart';
import '../sync/sync_service.dart';
import '../sync/sync_discovery.dart';
import '../storage/settings_store.dart';

const _kAccent = Color(0xFF007AFF);
const _kTextPrimary = Color(0xFF1C1C1E);
const _kTextSecondary = Color(0xFF8E8E93);
const _kSeparator = Color(0xFFE5E5EA);
const _kSurface = Color(0xFFFFFFFF);

class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  @override
  void initState() {
    super.initState();
    SyncService.instance.onPairingRequest = _showPairingDialog;
    SyncService.instance.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SyncService.instance.onPairingRequest = null;
    SyncService.instance.removeListener(_rebuild);
    super.dispose();
  }

  void _showPairingDialog(String peerId, String peerName, String pin) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('配对请求',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: _kTextPrimary)),
              const SizedBox(height: 6),
              Text('"$peerName" 想要配对',
                  style: const TextStyle(
                      fontSize: 13, color: _kTextSecondary)),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(pin,
                    style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 8,
                        color: _kAccent)),
              ),
              const SizedBox(height: 8),
              const Text('请让对方在其设备上输入这个 PIN 码',
                  style: TextStyle(fontSize: 11, color: _kTextSecondary)),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _btn('取消配对',
                      bg: const Color(0xFFE5E5EA),
                      fg: _kTextPrimary,
                      onTap: () {
                        Navigator.pop(ctx);
                        SyncService.instance.rejectPairing(peerId);
                      }),
                  const SizedBox(width: 8),
                  _btn('知道了',
                      bg: _kAccent,
                      fg: Colors.white,
                      onTap: () {
                        Navigator.pop(ctx);
                        SyncService.instance.confirmPairing(peerId);
                      }),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _btn(String label,
      {required Color bg,
      required Color fg,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
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

  @override
  Widget build(BuildContext context) {
    final settings = SettingsStore();
    final sync = SyncService.instance;
    final paired = sync.pairedPeers;
    final discovered = sync.discoveredPeers;

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 24),
      children: [
        // Local device info
        _section('本机', [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _kAccent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.laptop_windows,
                      size: 20, color: _kAccent),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Windows 设备',
                        style: TextStyle(
                            fontSize: 13, color: _kTextPrimary)),
                    Text(
                      settings.syncLocalDeviceId.length > 8
                          ? '${settings.syncLocalDeviceId.substring(0, 8)}…'
                          : settings.syncLocalDeviceId,
                      style: const TextStyle(
                          fontSize: 11,
                          color: _kTextSecondary,
                          fontFamily: 'Consolas'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ]),
        const SizedBox(height: 14),

        // Sync now button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _SyncButton(onTap: sync.manualSync),
        ),
        const SizedBox(height: 20),

        // Paired devices
        _section('已配对设备 (${paired.length})', [
          if (paired.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Text('暂无已配对设备',
                  style: TextStyle(
                      fontSize: 13, color: _kTextSecondary)),
            )
          else
            for (int i = 0; i < paired.length; i++) ...[
              _PeerRow(
                peer: paired[i],
                isOnline: sync.isPeerOnline(paired[i].id),
                trailing: null,
              ),
              if (i < paired.length - 1)
                const Divider(
                    height: 1,
                    thickness: 0.5,
                    indent: 16,
                    color: _kSeparator),
            ],
        ]),
        const SizedBox(height: 20),

        // Discovered devices
        _section('局域网设备 (${discovered.length})', [
          if (discovered.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: _kTextSecondary),
                  ),
                  SizedBox(width: 10),
                  Text('正在扫描局域网…',
                      style: TextStyle(
                          fontSize: 13, color: _kTextSecondary)),
                ],
              ),
            )
          else
            for (int i = 0; i < discovered.length; i++) ...[
              _PeerRow(
                peer: discovered[i],
                isOnline: true,
                trailing: paired.any((p) => p.id == discovered[i].id)
                    ? _badge('已配对', _kAccent)
                    : _pairBtn(discovered[i], sync),
              ),
              if (i < discovered.length - 1)
                const Divider(
                    height: 1,
                    thickness: 0.5,
                    indent: 16,
                    color: _kSeparator),
            ],
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
          child: Column(children: rows),
        ),
      ],
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w500)),
    );
  }

  Widget _pairBtn(DiscoveredPeer peer, SyncService sync) {
    return GestureDetector(
      onTap: () async {
        await sync.connectTo(peer);
        if (!mounted) return;
        _showOutgoingPinDialog(peer, sync);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: _kAccent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Text('配对',
            style: TextStyle(
                fontSize: 12,
                color: Colors.white,
                fontWeight: FontWeight.w500)),
      ),
    );
  }

  void _showOutgoingPinDialog(DiscoveredPeer peer, SyncService sync) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('输入配对 PIN',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: _kTextPrimary)),
              const SizedBox(height: 6),
              Text('请输入 "$peer.name" 上显示的 6 位 PIN',
                  style: const TextStyle(fontSize: 13, color: _kTextSecondary)),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 6,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 6,
                  color: _kAccent,
                ),
                decoration: const InputDecoration(
                  counterText: '',
                  hintText: '000000',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _btn('取消',
                      bg: const Color(0xFFE5E5EA),
                      fg: _kTextPrimary,
                      onTap: () {
                        Navigator.pop(ctx);
                      }),
                  const SizedBox(width: 8),
                  _btn('发送 PIN',
                      bg: _kAccent,
                      fg: Colors.white,
                      onTap: () {
                        if (controller.text.length != 6) return;
                        sync.submitPairingPin(peer.id, controller.text);
                        Navigator.pop(ctx);
                      }),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Peer row ─────────────────────────────────────────────────────────────

class _PeerRow extends StatelessWidget {
  final dynamic peer;
  final bool isOnline;
  final Widget? trailing;
  const _PeerRow(
      {required this.peer, required this.isOnline, required this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isOnline
                  ? const Color(0xFFE8F5E9)
                  : const Color(0xFFF2F2F7),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(
              Icons.devices,
              size: 17,
              color: isOnline
                  ? const Color(0xFF34C759)
                  : _kTextSecondary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(peer.name,
                    style: const TextStyle(
                        fontSize: 13, color: _kTextPrimary)),
                Text(
                  isOnline ? '在线' : '离线',
                  style: TextStyle(
                    fontSize: 11,
                    color: isOnline
                        ? const Color(0xFF34C759)
                        : _kTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

// ─── Sync button ──────────────────────────────────────────────────────────

class _SyncButton extends StatefulWidget {
  final VoidCallback onTap;
  const _SyncButton({required this.onTap});

  @override
  State<_SyncButton> createState() => _SyncButtonState();
}

class _SyncButtonState extends State<_SyncButton> {
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
          height: 36,
          decoration: BoxDecoration(
            color: _hovered
                ? const Color(0xFF0071E3)
                : _kAccent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.sync_rounded, size: 16, color: Colors.white),
              SizedBox(width: 6),
              Text('立即同步',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}
