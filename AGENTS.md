# Repository Guidelines

## Project Structure & Module Organization
This is a Windows-focused Flutter desktop app. Keep app code in `lib/` and treat generated output as disposable.

- `lib/main.dart`: app bootstrap, tray/window lifecycle, global hotkey, shell UI.
- `lib/core/`: clipboard polling, auto-paste, privacy filtering.
- `lib/storage/`: singleton stores and persistence.
- `lib/sync/`: discovery, crypto, connections, and sync orchestration.
- `lib/views/` and `lib/view_models/`: page UI and page-facing state logic.
- `lib/models/`: data models with manual JSON methods.
- `assets/`: runtime assets such as `assets/icon.ico`.
- `test/`: Flutter tests. Update `test/widget_test.dart`; it is still the default template.
- `windows/`: native Windows runner files. Avoid manual edits unless the change is platform-specific.
- Ignore `build/`, `.dart_tool/`, and `windows/flutter/ephemeral/`.

## Build, Test, and Development Commands
- `flutter pub get`: install or refresh dependencies.
- `flutter run -d windows`: run the desktop app locally. The app starts hidden; use `Alt+V` to show it.
- `flutter analyze`: run Dart and Flutter lints from `flutter_lints`.
- `flutter test`: run all tests.
- `flutter test test/widget_test.dart`: run a single test file.
- `flutter build windows --release`: produce a release build under `build/windows/x64/runner/Release/`.
- `dart run build_runner build --delete-conflicting-outputs`: regenerate code if codegen is introduced later.

## Coding Style & Naming Conventions
Follow `analysis_options.yaml` and format with `dart format .` before opening a PR. Use 2-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for members, and `snake_case.dart` for filenames. Prefer keeping business logic in `core/`, `storage/`, or `sync/` rather than in widgets. When importing Win32 APIs alongside Flutter, alias the package as `win32`.

## Testing Guidelines
Use `flutter_test` for widget and unit tests. Name test files `*_test.dart` and keep them near the feature area they cover. Add tests for store behavior, sync message handling, and clipboard filtering logic. Do not rely only on manual tray testing.

## Commit & Pull Request Guidelines
This workspace snapshot does not include `.git`, so commit conventions could not be verified from local history. Use short imperative commit subjects such as `Add sync device timeout handling`. Keep commits focused. PRs should include a brief behavior summary, linked issue if applicable, test results from `flutter analyze` and `flutter test`, and screenshots or short recordings for UI or tray behavior changes.

## Configuration Notes
Preserve compatibility with the Windows tray/hotkey flow and the existing sync wire format. If you change icons, update both `assets/icon.ico` and `windows/runner/resources/app_icon.ico`.
