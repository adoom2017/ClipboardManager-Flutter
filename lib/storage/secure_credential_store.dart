import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart';

/// Stores Windows secrets protected for the current user with DPAPI.
class SecureCredentialStore {
  SecureCredentialStore(this._prefs);

  final SharedPreferences _prefs;

  String? read(String key) {
    final stored = _prefs.getString(_storageKey(key));
    if (stored == null || stored.isEmpty) return null;
    if (!Platform.isWindows) return stored;

    try {
      return utf8.decode(_unprotect(base64.decode(stored)));
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, String value) async {
    if (value.isEmpty) {
      await _prefs.remove(_storageKey(key));
      return;
    }
    final stored = Platform.isWindows
        ? base64.encode(_protect(utf8.encode(value)))
        : value;
    await _prefs.setString(_storageKey(key), stored);
  }

  String _storageKey(String key) => 'secure.$key';

  List<int> _protect(List<int> bytes) => _transform(bytes, protect: true);
  List<int> _unprotect(List<int> bytes) => _transform(bytes, protect: false);

  List<int> _transform(List<int> bytes, {required bool protect}) {
    final inputBytes = calloc<Uint8>(bytes.length);
    final input = calloc<CRYPT_INTEGER_BLOB>();
    final output = calloc<CRYPT_INTEGER_BLOB>();
    inputBytes.asTypedList(bytes.length).setAll(0, bytes);
    input.ref
      ..cbData = bytes.length
      ..pbData = inputBytes;

    try {
      final ok = protect
          ? CryptProtectData(
              input,
              nullptr.cast<Utf16>(),
              nullptr.cast<CRYPT_INTEGER_BLOB>(),
              nullptr,
              nullptr.cast<CRYPTPROTECT_PROMPTSTRUCT>(),
              1,
              output,
            )
          : CryptUnprotectData(
              input,
              nullptr.cast<Pointer<Utf16>>(),
              nullptr.cast<CRYPT_INTEGER_BLOB>(),
              nullptr,
              nullptr.cast<CRYPTPROTECT_PROMPTSTRUCT>(),
              1,
              output,
            );
      if (ok == 0) throw StateError('DPAPI operation failed');
      return List<int>.from(output.ref.pbData.asTypedList(output.ref.cbData));
    } finally {
      if (output.ref.pbData != nullptr) LocalFree(output.ref.pbData.cast());
      calloc.free(inputBytes);
      calloc.free(input);
      calloc.free(output);
    }
  }
}
