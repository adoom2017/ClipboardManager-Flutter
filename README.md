# Clipboard Manager for Windows

Flutter 桌面剪贴板管理器，是 `clipboard` 工作区的 Windows 客户端。

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

发布包使用 Windows 主机构建：

```bash
flutter build windows --release
```

正式版便携包：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-release.ps1
```

产物位于 `build\release\`。代码签名参数见[开发指南](../docs/development.md#windows-打包)。

统一文档位于工作区根目录：

- [项目总览](../README.md)
- [用户指南](../docs/user-guide.md)
- [系统架构](../docs/architecture.md)
- [开发指南](../docs/development.md)
- [同步协议](../docs/sync-protocol.md)
