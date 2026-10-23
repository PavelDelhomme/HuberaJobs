import 'package:flutter_test/flutter_test.dart';
import 'package:jobbingtrack_mobile/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('L’application monte puis affiche l’écran de connexion', (WidgetTester tester) async {
    await tester.pumpWidget(const JobbingTrackMobileApp());
    await tester.pump();
    expect(find.text('Hubera Jobs'), findsWidgets);

    // Le splash enchaîne vers /login (async) — avancer le temps sans bloquer indéfiniment.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.text('Connexion').evaluate().isNotEmpty) break;
    }

    expect(find.text('Connexion'), findsOneWidget);
    expect(find.textContaining('candidatures'), findsOneWidget);
  });
}
