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

加 `-CreateInstaller` 会额外用 Inno Setup 6 生成安装程序 `ClipboardManager-Windows-<version>-Setup.exe`。产物位于 `build\release\`。代码签名参数见[开发指南](https://github.com/adoom2017/ClipboardManager/blob/main/docs/development.md#windows-打包)。

## 持续集成与发布

`.github/workflows/windows.yml` 在推送到 `master`、Pull Request 和手动触发时执行分析、测试、编译，并上传 ZIP 和安装程序（保留 14 天）。

推送 `v<major>.<minor>.<patch>` 标签时自动创建 GitHub Release，附带 ZIP、安装程序及对应的 SHA-256 文件。版本号取自标签：

```bash
git tag v1.2.0
git push origin v1.2.0
```

CI 产物未签名，首次运行时 Windows SmartScreen 可能提示风险。

统一文档位于 macOS 仓库：

- [项目总览](../README.md)
- [用户指南](https://github.com/adoom2017/ClipboardManager/blob/main/docs/user-guide.md)
- [系统架构](https://github.com/adoom2017/ClipboardManager/blob/main/docs/architecture.md)
- [开发指南](https://github.com/adoom2017/ClipboardManager/blob/main/docs/development.md)
- [同步协议](https://github.com/adoom2017/ClipboardManager/blob/main/docs/sync-protocol.md)
