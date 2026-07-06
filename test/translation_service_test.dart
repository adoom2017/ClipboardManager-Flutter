import 'package:clipboard_manager/core/translation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeModelOutput', () {
    test('removes multiline thinking blocks', () {
      const output = '''
<think>
Analyze the source and choose the best wording.
</think>
最终翻译
''';

      expect(TranslationService.sanitizeModelOutput(output), '最终翻译');
    });

    test('removes multiple case-insensitive thinking blocks', () {
      const output = "<THINK>first</THINK>结果<think data-x='1'>second</think>";

      expect(TranslationService.sanitizeModelOutput(output), '结果');
    });

    test('drops an unclosed thinking block', () {
      const output = '最终结果\n<think>unfinished reasoning';

      expect(TranslationService.sanitizeModelOutput(output), '最终结果');
    });
  });
}
