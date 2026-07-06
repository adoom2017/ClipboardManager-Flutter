import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'secure_credential_store.dart';

class SettingsStore extends ChangeNotifier {
  static final SettingsStore _instance = SettingsStore._internal();
  factory SettingsStore() => _instance;
  SettingsStore._internal();

  late SharedPreferences _prefs;
  late SecureCredentialStore _secureStore;

  // Defaults
  int _maxHistoryCount = 100;
  int _retainDays = 7;
  bool _privacyGuardEnabled = true;
  bool _launchAtStartup = false;
  String _translationApiUrl = 'https://api.openai.com/v1';
  String _translationApiKey = '';
  String _translationModel = 'gpt-4o-mini';
  String _syncLocalDeviceId = '';
  String _syncPin = '';

  int get maxHistoryCount => _maxHistoryCount;
  int get retainDays => _retainDays;
  bool get privacyGuardEnabled => _privacyGuardEnabled;
  bool get launchAtStartup => _launchAtStartup;
  String get translationApiUrl => _translationApiUrl;
  String get translationApiKey => _translationApiKey;
  String get translationModel => _translationModel;
  String get syncLocalDeviceId => _syncLocalDeviceId;
  String get syncPin => _syncPin;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _secureStore = SecureCredentialStore(_prefs);
    _maxHistoryCount = _prefs.getInt('maxHistoryCount') ?? 100;
    _retainDays = _prefs.getInt('retainDays') ?? 7;
    _privacyGuardEnabled = _prefs.getBool('privacyGuard') ?? true;
    _launchAtStartup = _prefs.getBool('launchAtStartup') ?? false;
    _translationApiUrl =
        _prefs.getString('translationApiUrl') ?? 'https://api.openai.com/v1';
    final legacyApiKey = _prefs.getString('translationApiKey') ?? '';
    _translationApiKey = _secureStore.read('translationApiKey') ?? legacyApiKey;
    if (legacyApiKey.isNotEmpty) {
      await _secureStore.write('translationApiKey', legacyApiKey);
      await _prefs.remove('translationApiKey');
    }
    _translationModel = _prefs.getString('translationModel') ?? 'gpt-4o-mini';
    _syncLocalDeviceId =
        _prefs.getString('syncLocalDeviceID') ?? _generateDeviceId();
    _syncPin = _secureStore.read('syncPin') ?? '';
  }

  String _generateDeviceId() {
    final id = const Uuid().v4();
    _prefs.setString('syncLocalDeviceID', id);
    return id;
  }

  Future<void> setMaxHistoryCount(int v) async {
    _maxHistoryCount = v;
    await _prefs.setInt('maxHistoryCount', v);
    notifyListeners();
  }

  Future<void> setRetainDays(int v) async {
    _retainDays = v;
    await _prefs.setInt('retainDays', v);
    notifyListeners();
  }

  Future<void> setPrivacyGuardEnabled(bool v) async {
    _privacyGuardEnabled = v;
    await _prefs.setBool('privacyGuard', v);
    notifyListeners();
  }

  Future<void> setLaunchAtStartup(bool v) async {
    _launchAtStartup = v;
    await _prefs.setBool('launchAtStartup', v);
    await _applyStartupRegistry(v);
    notifyListeners();
  }

  Future<void> setTranslationApiUrl(String v) async {
    _translationApiUrl = v;
    await _prefs.setString('translationApiUrl', v);
    notifyListeners();
  }

  Future<void> setTranslationApiKey(String v) async {
    _translationApiKey = v;
    await _secureStore.write('translationApiKey', v);
    notifyListeners();
  }

  Future<void> setSyncPin(String value) async {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    _syncPin = digits.substring(0, digits.length.clamp(0, 6));
    await _secureStore.write('syncPin', _syncPin);
    notifyListeners();
  }

  Future<void> setTranslationModel(String v) async {
    _translationModel = v;
    await _prefs.setString('translationModel', v);
    notifyListeners();
  }

  Future<void> _applyStartupRegistry(bool enable) async {
    if (!Platform.isWindows) return;
    const regPath =
        r'HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';
    const keyName = 'ClipboardManager';
    final exePath = Platform.resolvedExecutable;
    if (enable) {
      await Process.run('reg', [
        'add',
        regPath,
        '/v',
        keyName,
        '/t',
        'REG_SZ',
        '/d',
        '"$exePath"',
        '/f',
      ]);
    } else {
      await Process.run('reg', ['delete', regPath, '/v', keyName, '/f']);
    }
  }
}
