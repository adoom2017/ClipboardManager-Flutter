import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

enum AppLogLevel {
  debug(0, 'DEBUG'),
  info(1, 'INFO'),
  warn(2, 'WARN'),
  error(3, 'ERROR');

  const AppLogLevel(this.priority, this.label);
  final int priority;
  final String label;
}

class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  static const _logFileName = 'app.log';
  static const _maxFileSizeBytes = 1024 * 1024;
  static const _maxTotalSizeBytes = 20 * 1024 * 1024;
  static const _retentionDays = 7;
  static const _cleanupInterval = Duration(hours: 24);

  final AppLogLevel minimumLevel = AppLogLevel.info;

  Directory? _logsDirectory;
  File? _currentLogFile;
  Timer? _cleanupTimer;
  Future<void> _writeChain = Future.value();
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    await _prepare();
    await _cleanup();
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(_cleanupInterval, (_) {
      unawaited(_enqueue(_cleanup));
    });
    _initialized = true;
    info('Logger', 'initialized path=${_logsDirectory?.path ?? "unknown"} level=${minimumLevel.label}');
  }

  void debug(String category, String message) => log(AppLogLevel.debug, category, message);
  void info(String category, String message) => log(AppLogLevel.info, category, message);
  void warn(String category, String message) => log(AppLogLevel.warn, category, message);
  void error(String category, String message) => log(AppLogLevel.error, category, message);

  void log(AppLogLevel level, String category, String message) {
    if (level.priority < minimumLevel.priority) return;
    final line = '${DateTime.now().toUtc().toIso8601String()} [${level.label}] [$category] $message';
    stdout.writeln(line);
    if (!_initialized) return;

    unawaited(_enqueue(() async {
      await _prepare();
      await _rotateIfNeeded(line.length + 1);
      await _currentLogFile!.writeAsString('$line\n', mode: FileMode.append, flush: false);
    }));
  }

  Future<void> dispose() async {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    await _writeChain;
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _writeChain = _writeChain.then((_) => action());
    return _writeChain;
  }

  Future<void> _prepare() async {
    if (_logsDirectory != null && _currentLogFile != null) return;

    final appSupport = await getApplicationSupportDirectory();
    final logsDir = Directory('${appSupport.path}${Platform.pathSeparator}Logs');
    if (!await logsDir.exists()) {
      await logsDir.create(recursive: true);
    }

    final currentFile = File('${logsDir.path}${Platform.pathSeparator}$_logFileName');
    if (!await currentFile.exists()) {
      await currentFile.create(recursive: true);
    }

    _logsDirectory = logsDir;
    _currentLogFile = currentFile;
  }

  Future<void> _rotateIfNeeded(int additionalBytes) async {
    final file = _currentLogFile;
    final dir = _logsDirectory;
    if (file == null || dir == null) return;

    final currentSize = await file.length();
    if (currentSize + additionalBytes <= _maxFileSizeBytes) return;

    final timestamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-');
    final rotated = File('${dir.path}${Platform.pathSeparator}app-$timestamp.log');
    if (await rotated.exists()) {
      await rotated.delete();
    }
    await file.rename(rotated.path);
    _currentLogFile = File('${dir.path}${Platform.pathSeparator}$_logFileName');
    await _currentLogFile!.create(recursive: true);
    await _cleanup();
  }

  Future<void> _cleanup() async {
    final dir = _logsDirectory;
    if (dir == null || !await dir.exists()) return;

    final now = DateTime.now();
    final retentionCutoff = now.subtract(const Duration(days: _retentionDays));
    final entries = await dir.list().where((entry) => entry is File).cast<File>().toList();

    final fileInfos = <_LogFileInfo>[];
    for (final file in entries) {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) continue;
      if (stat.modified.isBefore(retentionCutoff)) {
        await file.delete();
        continue;
      }
      fileInfos.add(_LogFileInfo(file, stat.modified, stat.size));
    }

    fileInfos.sort((a, b) => a.modified.compareTo(b.modified));
    var totalSize = fileInfos.fold<int>(0, (sum, info) => sum + info.size);
    for (final info in fileInfos) {
      if (totalSize <= _maxTotalSizeBytes) break;
      if (info.file.path == _currentLogFile?.path) continue;
      await info.file.delete();
      totalSize -= info.size;
    }
  }
}

class _LogFileInfo {
  const _LogFileInfo(this.file, this.modified, this.size);

  final File file;
  final DateTime modified;
  final int size;
}
