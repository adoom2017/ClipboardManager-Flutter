# Copilot Instructions — Windows

统一文档位于工作区 `../docs/`；优先阅读 `../docs/architecture.md`、`../docs/development.md` 和 `../docs/sync-protocol.md`。

Windows 客户端红线：

- 保持托盘、`Alt+V`、失焦隐藏、目标窗口恢复和自动粘贴流程可用。
- `calloc` 分配的 Win32 FFI 内存必须释放；API Key 与同步 PIN 必须经 DPAPI 保护。
- `ClipboardStore`、`SettingsStore`、`SyncService` 保持 factory singleton 语义。
- 同步帧使用 4 字节大端长度头；只接受 `encryptedPayload`，不得增加明文回退。
- 修改图标时同时更新托盘和 runner 的 `.ico` 文件。
- 构建、测试和 Windows 手工验证清单以 `../docs/development.md` 为准。
