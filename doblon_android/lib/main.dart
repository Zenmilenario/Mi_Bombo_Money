import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data.dart';
import 'screens/login.dart';
import 'screens/shell.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es');
  await Supabase.initialize(url: supabaseUrl, publishableKey: supabasePublishableKey);
  runApp(const DoblonApp());
}

class DoblonApp extends StatelessWidget {
  const DoblonApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Doblón',
      debugShowCheckedModeBanner: false,
      theme: doblonTheme(Brightness.light),
      darkTheme: doblonTheme(Brightness.dark),
      locale: const Locale('es', 'ES'),
      supportedLocales: const [Locale('es', 'ES')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: const AuthGate(),
    );
  }
}

/// Shows the sign-in screen or the finances, following the Supabase session.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = Supabase.instance.client.auth;
    return StreamBuilder<AuthState>(
      stream: auth.onAuthStateChange,
      builder: (context, _) => auth.currentSession == null ? const LoginScreen() : const Shell(),
    );
  }
}
