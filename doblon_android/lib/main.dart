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
        // The lock wraps the navigator: every screen, also one opened on top, stays under it.
        builder: (context, child) => LockGate(preferences: preferences, child: child!),
        home: AuthGate(preferences: preferences),
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
      builder: (context, _) =>
          auth.currentSession == null ? const LoginScreen() : CloudPrivacyGate(key: ValueKey(auth.currentUser!.id), child: Shell(preferences: preferences)),
    );
  }
}

/// With the lock on, the app is covered on opening and when it comes back from the background, until the
/// phone's fingerprint, face, PIN or pattern, or the account's email and password, confirm it is its owner.
///
/// It wraps the whole navigation (MaterialApp.builder): an open screen (an account, a movement) is covered too, and
/// the tab and screens stay alive underneath, hidden, so the person returns where they were. As soon as the app
/// stops being active a privacy cover hides the content (also in the recent apps view); on return it stays hidden
/// until unlocked.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.preferences, required this.child, this.authenticator = authenticate, this.passwordCheck = checkPassword});
  final AppPreferences preferences;
  final Widget child;

  /// Face ID, fingerprint or the phone's own code (`authenticate`); replaced in the tests.
  final Future<bool> Function(String reason) authenticator;

  /// The account's email and password, through the existing sign-in (`checkPassword`); replaced in the tests.
  final Future<String?> Function(String email, String password) passwordCheck;
  @override
  State<LockGate> createState() => _LockGateState();
}

/// Confirms the email and password of the account already signed in, with the existing Supabase sign-in: the
/// session is renewed, never closed. Null when it is correct; otherwise what to tell the person.
Future<String?> checkPassword(String email, String password) async {
  final auth = Supabase.instance.client.auth;
  final current = auth.currentUser?.email;
  if (current != null && current.toLowerCase() != email.trim().toLowerCase()) {
    return 'Usa el correo de esta cuenta. Para entrar con otra, desbloquea y sal de la cuenta.';
  }
  try {
    await auth.signInWithPassword(email: email.trim(), password: password);
    return null;
  } on AuthException {
    return 'Correo o contraseña incorrectos.';
  } catch (_) {
    return 'No se ha podido comprobar. Revisa la conexión e inténtalo de nuevo.';
  }
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  late bool locked = widget.preferences.lockEnabled;

  /// The app is built only after the first unlock: on opening, loading and computing the finances under the lock
  /// delayed Face ID (0.29.0). From then on it stays alive under the lock, to return where the person was.
  late bool started = !locked;
  bool asking = false;

  /// While the app is not in front: the content is hidden by a cover (recent apps, switching apps).
  bool covered = false;

  /// After a failed or cancelled attempt: the screen says so and offers to try again or use the password.
  bool failed = false;
  bool checking = false;
  String? passwordMessage;
  final _email = TextEditingController(text: _currentEmail());
  final _password = TextEditingController();

  static String _currentEmail() {
    try {
      return Supabase.instance.client.auth.currentUser?.email ?? '';
    } catch (_) {
      return ''; // Without Supabase (tests).
    }
  }

  /// Asked once on opening and once after coming back from the background. The Face ID sheet itself makes the app
  /// inactive and active again: asking on every return to the foreground asked again after each failure, in a loop.
  bool askOnReturn = false;

  /// The lock screen lives in its own navigator, built once: it listens to this to show each change.
  final _tick = ValueNotifier(0);

  void _update(VoidCallback change) {
    setState(change);
    _tick.value++;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _email.dispose();
    _password.dispose();
    _tick.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.preferences.lockEnabled) {
      if (covered) _update(() => covered = false);
      return;
    }
    // Hidden at once, before the system takes the picture for the recent apps.
    final away = state != AppLifecycleState.resumed;
    if (away != covered) _update(() => covered = away);
    if (asking) return; // The biometric sheet itself makes the app inactive: never lock or ask because of it.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      askOnReturn = true;
      if (!locked) {
        _update(() {
          locked = true;
          failed = false;
          passwordMessage = null;
        });
      }
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
    if (!mounted) return;
    _update(() {
      if (ok) {
        locked = false;
        _password.clear();
      }
      failed = !ok;
    });
  }

  Future<void> _withPassword() async {
    if (checking) return;
    if (_email.text.trim().isEmpty || _password.text.isEmpty) {
      _update(() => passwordMessage = 'Escribe tu correo y tu contraseña.');
      return;
    }
    _update(() {
      checking = true;
      passwordMessage = null;
    });
    final problem = await widget.passwordCheck(_email.text, _password.text);
    if (!mounted) return;
    _update(() {
      checking = false;
      passwordMessage = problem;
      if (problem == null) {
        locked = false;
        failed = false;
        _password.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.preferences.lockEnabled;
    final hideContent = enabled && (locked || covered);
    if (!started && !(enabled && locked)) started = true;
    // Told after this frame: listeners may rebuild other widgets.
    final isLocked = enabled && locked;
    if (appLocked.value != isLocked) WidgetsBinding.instance.addPostFrameCallback((_) => appLocked.value = isLocked);
    return Stack(fit: StackFit.expand, children: [
      // Alive but not painted, not readable and not touchable while locked or covered.
      if (started) Offstage(offstage: hideContent, child: TickerMode(enabled: !hideContent, child: widget.child)),
      if (enabled && locked) _lockScreen(context) else if (enabled && covered) const PrivacyCover(),
    ]);
  }

  Widget _lockScreen(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    // Its own navigator: text fields and their menus need an overlay, and the app's is hidden underneath. Without the
    // app's hero controller, which belongs to the app's navigator.
    return HeroControllerScope.none(
        child: Navigator(
      onGenerateRoute: (_) => PageRouteBuilder(
        pageBuilder: (context, _, __) => ListenableBuilder(
          listenable: _tick,
          builder: (context, _) => Scaffold(
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: AutofillGroup(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Center(child: ClipOval(child: Image.asset('assets/don_bigotes.png', width: 96, height: 96, fit: BoxFit.cover))),
                        const SizedBox(height: 16),
                        const Text('Tu dinero, con calma.', textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 14),
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
                        const SizedBox(height: 14),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              Row(children: [
                                Icon(Icons.lock_outline, size: 14, color: pulso.accent),
                                const SizedBox(width: 6),
                                Text('TU ESPACIO PERSONAL', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: pulso.accent)),
                              ]),
                              const SizedBox(height: 8),
                              const Text('Doblón está bloqueado', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                              const SizedBox(height: 6),
                              Semantics(
                                liveRegion: true,
                                child: Text(
                                    failed
                                        ? 'No se ha desbloqueado. Vuelve a intentarlo o entra con tu correo y contraseña.'
                                        : 'Entra con Face ID o tu huella. Si no te reconoce, el sistema te deja usar el código de tu móvil.',
                                    style: TextStyle(color: failed ? pulso.warning : hint)),
                              ),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: asking ? null : _unlock,
                                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                                icon: const Icon(Icons.face),
                                label: Text(failed ? 'Volver a intentar con Face ID o huella' : 'Desbloquear',
                                    textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
                              ),
                              const SizedBox(height: 18),
                              Row(children: [
                                const Expanded(child: Divider()),
                                Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('o', style: TextStyle(color: hint))),
                                const Expanded(child: Divider()),
                              ]),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _email,
                                keyboardType: TextInputType.emailAddress,
                                autofillHints: const [AutofillHints.email],
                                decoration: const InputDecoration(labelText: 'Correo', border: OutlineInputBorder()),
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                controller: _password,
                                obscureText: true,
                                autofillHints: const [AutofillHints.password],
                                onSubmitted: (_) => _withPassword(),
                                decoration: const InputDecoration(labelText: 'Contraseña', border: OutlineInputBorder()),
                              ),
                              if (passwordMessage != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Semantics(liveRegion: true, child: Text(passwordMessage!, style: TextStyle(color: pulso.expense))),
                                ),
                              const SizedBox(height: 10),
                              OutlinedButton(
                                onPressed: checking ? null : _withPassword,
                                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                                child: Text(checking ? 'Comprobando…' : 'Entrar con correo y contraseña'),
                              ),
                            ]),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text('Cancelar Face ID no cierra tu sesión: tus datos siguen protegidos en este dispositivo.',
                            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: hint)),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
  }
}

/// Shown over the app while it is not in front (switching apps, recent apps), without any amount.
class PrivacyCover extends StatelessWidget {
  const PrivacyCover({super.key});

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    return ColoredBox(
      color: pulso.page,
      child: Center(
        child: Semantics(
          label: 'Doblón, contenido oculto',
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ClipOval(child: Image.asset('assets/don_bigotes.png', width: 88, height: 88, fit: BoxFit.cover)),
            const SizedBox(height: 12),
            Icon(Icons.lock_outline, color: pulso.accent),
          ]),
        ),
      ),
    );
  }
}
