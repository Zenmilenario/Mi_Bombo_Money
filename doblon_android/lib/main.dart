import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cloud_privacy.dart';
import 'data.dart';
import 'preferences.dart';
import 'presentation.dart' show quoteOfTheDay;
import 'screens/login.dart';
import 'screens/cloud_privacy_gate.dart';
import 'screens/shell.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es');
  await Supabase.initialize(url: supabaseUrl, publishableKey: supabasePublishableKey);
  // Signing out from any screen (also the privacy gate) leaves no unlocked key in memory.
  Supabase.instance.client.auth.onAuthStateChange.listen((state) {
    if (state.event == AuthChangeEvent.signedOut) CloudPrivacy.forgetAll();
  });
  final preferences = AppPreferences();
  await preferences.load();
  runApp(DoblonApp(preferences: preferences));
}

class DoblonApp extends StatelessWidget {
  const DoblonApp({super.key, required this.preferences});
  final AppPreferences preferences;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: preferences,
      builder: (context, _) => MaterialApp(
        title: 'Doblón',
        debugShowCheckedModeBanner: false,
        theme: doblonTheme(Brightness.light),
        darkTheme: doblonTheme(Brightness.dark),
        themeMode: preferences.themeMode,
        locale: const Locale('es', 'ES'),
        supportedLocales: const [Locale('es', 'ES')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: LockGate(preferences: preferences, child: AuthGate(preferences: preferences)),
      ),
    );
  }
}

/// Shows the sign-in screen or the finances, following the Supabase session.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.preferences});
  final AppPreferences preferences;

  @override
  Widget build(BuildContext context) {
    final auth = Supabase.instance.client.auth;
    return StreamBuilder<AuthState>(
      stream: auth.onAuthStateChange,
      builder: (context, _) => auth.currentSession == null ? const LoginScreen() : CloudPrivacyGate(
        key: ValueKey(auth.currentUser!.id), child: Shell(preferences: preferences)),
    );
  }
}

/// With the lock on, the app is covered on opening and when it comes back from the background, until the
/// phone's fingerprint, face, PIN or pattern confirms it is its owner.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.preferences, required this.child, this.authenticator = authenticate});
  final AppPreferences preferences;
  final Widget child;

  /// Face ID, fingerprint or the phone's own code (`authenticate`); replaced in the tests.
  final Future<bool> Function(String reason) authenticator;
  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  late bool locked = widget.preferences.lockEnabled;
  bool asking = false;

  /// Asked once on opening and once after coming back from the background. The Face ID sheet itself makes the app
  /// inactive and active again: asking on every return to the foreground asked again after each failure, in a loop.
  bool askOnReturn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.preferences.lockEnabled || asking) return;
    if (state == AppLifecycleState.paused) {
      askOnReturn = true;
      setState(() => locked = true);
    }
    if (state == AppLifecycleState.resumed && locked && askOnReturn) {
      askOnReturn = false;
      _unlock();
    }
  }

  Future<void> _unlock() async {
    if (asking) return;
    asking = true;
    final ok = await widget.authenticator('Desbloquea Doblón');
    asking = false;
    if (ok && mounted) setState(() => locked = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!locked || !widget.preferences.lockEnabled) return widget.child;
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Center(child: ClipOval(child: Image.asset('assets/don_bigotes.png', width: 112, height: 112, fit: BoxFit.cover))),
                const SizedBox(height: 20),
                const Text('Tu dinero, con calma.', textAlign: TextAlign.center, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('LA FRASE DEL DÍA', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: pulso.accent)),
                      const SizedBox(height: 6),
                      Text(quoteOfTheDay(), style: const TextStyle(fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Icon(Icons.lock_outline, size: 14, color: pulso.accent),
                        const SizedBox(width: 6),
                        Text('TU ESPACIO PERSONAL', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: pulso.accent)),
                      ]),
                      const SizedBox(height: 8),
                      const Text('Doblón está bloqueado', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      Text('Entra con Face ID o tu huella. Si no te reconoce, el sistema te deja usar el código de tu móvil.',
                          style: TextStyle(color: hint)),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: _unlock,
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                        icon: const Icon(Icons.face),
                        label: const Text('Desbloquear', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 14),
                Text('El acceso protege tus finanzas en este dispositivo.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: hint)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
