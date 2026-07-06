# Windows Client Guidelines

先阅读工作区 `../AGENTS.md` 与 `../docs/development.md`。架构和协议事实不要重复维护在本文件。

Windows 客户端红线：

- 保持托盘、`Alt+V`、失焦隐藏和自动粘贴流程可用。
- `ClipboardStore`、`SettingsStore`、`SyncService` 是 factory singleton，通过 `ChangeNotifierProvider.value` 注入。
- 凭据必须经 `SecureCredentialStore`/DPAPI 保护。
- 同步只发送 `encryptedPayload`，不得增加明文回退。
- 修改图标时同时更新 `assets/icon.ico` 与 `windows/runner/resources/app_icon.ico`。
- 提交前运行 `flutter analyze`、`flutter test`，并在 Windows 验证平台能力。
