import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cloud_privacy.dart';
import 'data.dart';
import 'preferences.dart';
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
  const LockGate({super.key, required this.preferences, required this.child});
  final AppPreferences preferences;
  final Widget child;
  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  late bool locked = widget.preferences.lockEnabled;
  bool asking = false;

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
    if (state == AppLifecycleState.paused) setState(() => locked = true);
    if (state == AppLifecycleState.resumed && locked) _unlock();
  }

  Future<void> _unlock() async {
    if (asking) return;
    asking = true;
    final ok = await authenticate('Desbloquea Doblón');
    asking = false;
    if (ok && mounted) setState(() => locked = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!locked || !widget.preferences.lockEnabled) return widget.child;
    return Scaffold(
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipOval(child: Image.asset('assets/don_bigotes.png', width: 96, height: 96, fit: BoxFit.cover)),
          const SizedBox(height: 16),
          const Text('Doblón está bloqueado', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: _unlock, icon: const Icon(Icons.fingerprint), label: const Text('Desbloquear')),
        ]),
      ),
    );
  }
}
