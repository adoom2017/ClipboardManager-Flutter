import '../models/clipboard_item.dart';
import '../storage/settings_store.dart';

class PrivacyGuard {
  static const _blockedKeywords = [
    'password', 'secret', 'token', 'api_key', 'private_key',
    '密码', '口令', '密钥',
  ];

  static const _blockedApps = [
    '1password', 'bitwarden', 'keepass', 'lastpass', 'dashlane',
    'keychain', 'enpass', 'roboform',
  ];

  static bool isAllowed(ClipboardItem item) {
    if (!SettingsStore().privacyGuardEnabled) return true;
    if (item.contentType != ClipboardContentType.text) return true;

    final contentLower = item.content.toLowerCase();
    for (final kw in _blockedKeywords) {
      if (contentLower.contains(kw)) return false;
    }

    final appLower = item.sourceApp.toLowerCase();
    for (final app in _blockedApps) {
      if (appLower.contains(app)) return false;
    }

    return true;
  }
}
