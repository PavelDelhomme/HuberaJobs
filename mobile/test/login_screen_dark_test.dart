import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobbingtrack_mobile/providers/auth_provider.dart';
import 'package:jobbingtrack_mobile/screens/jobbing/auth/login_screen.dart';
import 'package:jobbingtrack_mobile/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

double _channel(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color color) =>
    0.2126 * _channel(color.r) + 0.7152 * _channel(color.g) + 0.0722 * _channel(color.b);

double _contrast(Color a, Color b) {
  final l1 = _luminance(a);
  final l2 = _luminance(b);
  final lighter = math.max(l1, l2);
  final darker = math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

void _mockPlugins() {
  const channels = <String>[
    'plugins.it_nomads.com/flutter_secure_storage',
    'plugins.flutter.io/local_auth',
  ];
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in channels) {
    messenger.setMockMethodCallHandler(MethodChannel(name), (call) async => null);
  }
}

Future<void> _pumpLogin(WidgetTester tester, ThemeData theme) async {
  await tester.binding.setSurfaceSize(const Size(800, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => AuthProvider(),
      child: MaterialApp(
        theme: theme,
        home: const LoginScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  final add = find.text('Ajouter un compte');
  if (add.evaluate().isNotEmpty) {
    await tester.tap(add);
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _mockPlugins();
  });

  testWidgets('connexion manuelle lisible et saisissable en thème sombre', (tester) async {
    await _pumpLogin(tester, AppTheme.dark());

    expect(find.byKey(const Key('manual-login-email')), findsOneWidget);
    expect(find.byKey(const Key('manual-login-password')), findsOneWidget);
    expect(find.text('Se connecter'), findsOneWidget);
    expect(find.text('Garder la connexion'), findsOneWidget);

    final card = tester.widget<Material>(find.byKey(const Key('manual-login-card')));
    final email = tester.widget<TextField>(find.byKey(const Key('manual-login-email')));
    final password = tester.widget<TextField>(find.byKey(const Key('manual-login-password')));
    final keep = tester.widget<Text>(find.text('Garder la connexion'));
    final button = tester.widget<ElevatedButton>(find.byKey(const Key('manual-login-submit')));

    expect(card.color, isNot(Colors.white));
    expect(email.decoration?.fillColor, isNot(Colors.grey[50]));
    expect(password.decoration?.fillColor, email.decoration?.fillColor);

    final fill = email.decoration!.fillColor!;
    expect(_contrast(email.style!.color!, fill), greaterThanOrEqualTo(4.5));
    expect(_contrast(email.decoration!.labelStyle!.color!, fill), greaterThanOrEqualTo(4.5));
    expect(_contrast(keep.style!.color!, card.color!), greaterThanOrEqualTo(4.5));

    final bg = button.style!.backgroundColor!.resolve(const <WidgetState>{})!;
    final fg = button.style!.foregroundColor!.resolve(const <WidgetState>{})!;
    expect(_contrast(fg, bg), greaterThanOrEqualTo(4.5));
    expect(button.onPressed, isNotNull);

    await tester.ensureVisible(find.byKey(const Key('manual-login-email')));
    await tester.tap(find.byKey(const Key('manual-login-email')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('manual-login-email')), 'paul@example.com');
    await tester.enterText(find.byKey(const Key('manual-login-password')), 'motdepasse');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byKey(const Key('manual-login-email'))).controller?.text,
      'paul@example.com',
    );
    expect(
      tester.widget<TextField>(find.byKey(const Key('manual-login-password'))).controller?.text,
      'motdepasse',
    );
    expect(
      tester.widget<ElevatedButton>(find.byKey(const Key('manual-login-submit'))).onPressed,
      isNotNull,
    );
  });

  testWidgets('connexion manuelle reste lisible en thème clair', (tester) async {
    await _pumpLogin(tester, AppTheme.light());

    final email = tester.widget<TextField>(find.byKey(const Key('manual-login-email')));
    final fill = email.decoration!.fillColor!;
    expect(_contrast(email.style!.color!, fill), greaterThanOrEqualTo(4.5));

    final button = tester.widget<ElevatedButton>(find.byKey(const Key('manual-login-submit')));
    final bg = button.style!.backgroundColor!.resolve(const <WidgetState>{})!;
    final fg = button.style!.foregroundColor!.resolve(const <WidgetState>{})!;
    expect(_contrast(fg, bg), greaterThanOrEqualTo(4.5));
    expect(button.onPressed, isNotNull);
  });
}
