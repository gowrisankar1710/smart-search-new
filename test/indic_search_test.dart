import 'package:flutter_test/flutter_test.dart';
import 'package:smart_file_search/core/indexed_file.dart';
import 'package:smart_file_search/core/text_tools.dart';
import 'package:smart_file_search/services/search_engine.dart';

IndexedFile _image(String path, String text) => IndexedFile(path: path, size: 1, modifiedMs: 0)
  ..content = text
  ..source = ContentSource.ocr
  ..status = IndexStatus.indexed;

void main() {
  test('Hindi and Tamil words keep their vowel signs', () {
    expect(rawWords('हिंदी में बिल 2024').toList(), ['हिंदी', 'में', 'बिल', '2024']);
    expect(rawWords('தமிழ் ரசீது').toList(), ['தமிழ்', 'ரசீது']);
    // Tesseract puts zero-width non-joiners after Tamil words.
    expect(rawWords('வணக்கம்‌ உலகம்‌').toList(), ['வணக்கம்', 'உலகம்']);
  });

  test('text read in Hindi and Tamil is found by its words and phrases', () {
    final hindi = _image('/p/hindi.png', 'Invoice\nनमस्ते दुनिया बिल 2024');
    final tamil = _image('/p/tamil.png', 'வணக்கம்‌ உலகம்‌ ரசீது');
    final e = SearchEngine()
      ..upsert(hindi)
      ..upsert(tamil);
    for (final q in ['दुनिया', 'नमस्ते दुनिया', 'बिल 2024', 'invoice']) {
      expect(e.find(q).hits.map((h) => h.file.path), ['/p/hindi.png'], reason: q);
    }
    for (final q in ['ரசீது', 'வணக்கம் உலகம்', 'உலகம்']) {
      expect(e.find(q).hits.map((h) => h.file.path), ['/p/tamil.png'], reason: q);
    }
  });

  test('Hindi and Tamil file names are found', () {
    final e = SearchEngine()..upsert(IndexedFile(path: '/p/किराया रसीद.pdf', size: 1, modifiedMs: 0));
    expect(e.find('किराया').hits, hasLength(1));
    expect(e.find('रसीद').hits, hasLength(1));
  });
}
