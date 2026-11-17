import 'package:flutter_test/flutter_test.dart';
import 'package:smart_file_search/core/file_types.dart';

void main() {
  test('files fall into documents, images and videos', () {
    expect(categoryOf('pdf'), FileCategory.documents);
    expect(categoryOf('docx'), FileCategory.documents);
    expect(categoryOf('txt'), FileCategory.documents);
    expect(categoryOf('jpg'), FileCategory.images);
    expect(categoryOf('png'), FileCategory.images);
    expect(categoryOf('mp4'), FileCategory.videos);
    expect(categoryOf('mov'), FileCategory.videos);
    expect(categoryOf('zip'), isNull); // known by name only
    expect(categoryOf('mp3'), isNull);
  });
}
