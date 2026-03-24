import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xray_gui/src/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  testWidgets('home screen smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const XrayGuiApp());
    await tester.pumpAndSettle();

    expect(find.text('连接'), findsWidgets);
    expect(find.text('节点'), findsOneWidget);
    expect(find.text('当前节点'), findsOneWidget);
  });
}
