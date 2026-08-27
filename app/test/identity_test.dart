import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:comic_reader/source/comic_source.dart';

void main() {
  test('Dart identity matches the Python exporter', () async {
    final f = File('../work/sd1.pdf');
    if (!f.existsSync()) return; // skip if the sample isn't around
    final id = cheapIdentity(
      byteLength: await f.length(),
      head: await readHead(f),
      pageCount: 31,
    );
    // ignore: avoid_print
    print('DART_ID=$id  size=${await f.length()}');
    expect(id, 'b7fc47c809535ca8');
  });
}
