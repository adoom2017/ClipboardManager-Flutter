import 'dart:convert';
import 'package:http/http.dart' as http;

class TranslationService {
  /// Returns true if [text] is predominantly Chinese/CJK.
  static bool _isChinese(String text) {
    final cjkCount = text.runes.where((r) =>
        (r >= 0x4E00 && r <= 0x9FFF) || // CJK Unified Ideographs
        (r >= 0x3400 && r <= 0x4DBF) || // CJK Extension A
        (r >= 0x20000 && r <= 0x2A6DF)  // CJK Extension B
    ).length;
    return cjkCount > text.length * 0.1;
  }

  /// Returns target language label for the prompt.
  static String targetLanguage(String text) =>
      _isChinese(text) ? 'English' : 'Chinese (Simplified)';

  /// Returns a human-readable direction string.
  static String directionLabel(String text) =>
      _isChinese(text) ? '中文 → English' : 'English → 中文';

  /// Translate [text] using the configured LLM.
  ///
  /// Supports:
  /// - OpenAI-compatible APIs (OpenAI, DeepSeek, Groq, etc.)
  /// - Google Gemini (`generativelanguage.googleapis.com`)
  static Future<String> translate(
    String text, {
    required String apiUrl,
    required String apiKey,
    required String model,
  }) async {
    if (apiKey.isEmpty) throw Exception('请先在设置中填写 API Key');
    if (text.trim().isEmpty) throw Exception('内容为空');

    final target = targetLanguage(text);
    const prompt =
        'Translate the following text to {lang}. '
        'Return ONLY the translated text, no explanations, no quotes.';
    final systemPrompt = prompt.replaceFirst('{lang}', target);

    final isGemini = apiUrl.contains('generativelanguage.googleapis.com');
    return isGemini
        ? _callGemini(text, systemPrompt, apiUrl: apiUrl, apiKey: apiKey, model: model)
        : _callOpenAI(text, systemPrompt, apiUrl: apiUrl, apiKey: apiKey, model: model);
  }

  // ─── OpenAI-compatible ────────────────────────────────────────────────────

  static Future<String> _callOpenAI(
    String text,
    String systemPrompt, {
    required String apiUrl,
    required String apiKey,
    required String model,
  }) async {
    final base = apiUrl.endsWith('/') ? apiUrl.substring(0, apiUrl.length - 1) : apiUrl;
    final uri = Uri.parse('$base/chat/completions');

    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': model,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': text},
        ],
        'temperature': 0.3,
        'max_tokens': 2048,
      }),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception('API 错误 ${response.statusCode}: ${_extractError(response.body)}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final content = (json['choices'] as List<dynamic>?)
        ?.firstOrNull?['message']?['content'] as String?;
    if (content == null || content.isEmpty) throw Exception('返回内容为空');
    return content.trim();
  }

  // ─── Google Gemini ────────────────────────────────────────────────────────

  static Future<String> _callGemini(
    String text,
    String systemPrompt, {
    required String apiUrl,
    required String apiKey,
    required String model,
  }) async {
    final base = apiUrl.endsWith('/') ? apiUrl.substring(0, apiUrl.length - 1) : apiUrl;
    final uri = Uri.parse('$base/v1beta/models/$model:generateContent?key=$apiKey');

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'system_instruction': {
          'parts': [{'text': systemPrompt}]
        },
        'contents': [
          {
            'parts': [{'text': text}]
          }
        ],
        'generationConfig': {
          'temperature': 0.3,
          'maxOutputTokens': 2048,
        },
      }),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception('Gemini 错误 ${response.statusCode}: ${_extractError(response.body)}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final content = (json['candidates'] as List<dynamic>?)
        ?.firstOrNull?['content']?['parts']?[0]?['text'] as String?;
    if (content == null || content.isEmpty) throw Exception('Gemini 返回内容为空');
    return content.trim();
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  static String _extractError(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      return (json['error']?['message'] as String?) ??
          (json['error'] as String?) ??
          body.substring(0, body.length.clamp(0, 200));
    } catch (_) {
      return body.length > 200 ? '${body.substring(0, 200)}…' : body;
    }
  }
}
