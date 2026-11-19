import 'package:flutter_test/flutter_test.dart';
import 'package:smart_file_search/services/file_scan.dart';

void main() {
  test('paths listed under a Windows drive root lose the doubled backslash', () {
    // Dart lists "C:\" as "C:\\Users", so the skip list (C:\Users\…\AppData) never matched.
    expect(cleanPath(r'C:\\Users\User\AppData\Local', windows: true), r'C:\Users\User\AppData\Local');
    expect(cleanPath(r'C:\\Windows', windows: true), r'C:\Windows');
    expect(cleanPath(r'D:\\Photos\\trip.jpg', windows: true), r'D:\Photos\trip.jpg');
  });

  test('normal and network paths stay as they are', () {
    expect(cleanPath(r'C:\Users\User\Documents\a.pdf', windows: true), r'C:\Users\User\Documents\a.pdf');
    expect(cleanPath(r'\\server\share\a.pdf', windows: true), r'\\server\share\a.pdf');
    expect(cleanPath('/Users/me//x.txt', windows: false), '/Users/me//x.txt');
  });
}
