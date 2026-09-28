import 'package:flutter_test/flutter_test.dart';
import 'package:pc_speaker/app.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const PCSpeakerApp());
    expect(find.text('PC Speaker'), findsOneWidget);
  });
}
