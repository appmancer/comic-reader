import 'package:flutter_test/flutter_test.dart';
import 'package:comic_reader/main.dart';

void main() {
  testWidgets('library page prompts for a folder', (tester) async {
    await tester.pumpWidget(const ComicReaderApp());
    expect(find.text('Library'), findsOneWidget);
    expect(
      find.textContaining('Choose'),
      findsOneWidget,
      reason: 'empty state should tell the user what to do',
    );
  });
}
