import 'package:flutter/material.dart';
import '../sync/sync_service.dart';
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
    SyncService.instance.addListener(_rebuild);
    SyncService.instance.boostDiscovery();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SyncService.instance.removeListener(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsStore();
    final discovered = SyncService.instance.discoveredPeers;

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 24),
      children: [
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
                  child: const Icon(Icons.laptop_windows, size: 20, color: _kAccent),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Windows 设备', style: TextStyle(fontSize: 13, color: _kTextPrimary)),
                    Text(
                      settings.syncLocalDeviceId.length > 8
                          ? '${settings.syncLocalDeviceId.substring(0, 8)}…'
                          : settings.syncLocalDeviceId,
                      style: const TextStyle(
                        fontSize: 11,
                        color: _kTextSecondary,
                        fontFamily: 'Consolas',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ]),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '设备会在局域网内自动发现。点击剪贴板条目的同步按钮时，应用会临时连接目标设备并发送该条文本内容。',
            style: const TextStyle(fontSize: 13, color: _kTextSecondary, height: 1.4),
          ),
        ),
        const SizedBox(height: 20),
        _section('局域网服务 (${discovered.length})', [
          if (discovered.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: _kTextSecondary),
                  ),
                  SizedBox(width: 10),
                  Text('正在扫描局域网…', style: TextStyle(fontSize: 13, color: _kTextSecondary)),
                ],
              ),
            )
          else
            for (int i = 0; i < discovered.length; i++) ...[
              _PeerRow(peer: discovered[i]),
              if (i < discovered.length - 1)
                const Divider(height: 1, thickness: 0.5, indent: 16, color: _kSeparator),
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
}

class _PeerRow extends StatelessWidget {
  final dynamic peer;
  const _PeerRow({required this.peer});

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
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(7),
            ),
            child: const Icon(Icons.devices, size: 17, color: Color(0xFF34C759)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(peer.displayName, style: const TextStyle(fontSize: 13, color: _kTextPrimary)),
                Text(
                  '${peer.host}:${peer.port}',
                  style: const TextStyle(fontSize: 11, color: _kTextSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
