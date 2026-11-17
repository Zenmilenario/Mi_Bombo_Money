import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../password_policy.dart';
import '../presentation.dart';
import '../theme.dart';
import 'widgets.dart' show BomboIllustration;

/// Sign-in with the same Doblón account as on the iPhone. No financial data before signing in:
/// only the brand and a daily curiosity.
/// Where the confirmation e-mail returns: the same exact address the iPhone uses, already allowed in
/// Supabase (CloudBackend/project.json). Android opens Doblón with it and the session starts there.
const authRedirect = 'mibombomoney-cloud://auth';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _creating = false;
  String? _message;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _message = 'Escribe tu correo y tu contraseña.');
      return;
    }
    // A new account follows the cloud's rule; an existing password is checked only by the cloud.
    final problem = _creating ? passwordProblem(password) : null;
    if (problem != null) {
      setState(() => _message = problem);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final auth = Supabase.instance.client.auth;
    try {
      if (_creating) {
        final response = await auth.signUp(email: email, password: password, emailRedirectTo: authRedirect);
        if (response.session == null && mounted) {
          setState(() => _message = 'Te hemos enviado un correo. Ábrelo en este móvil y pulsa el enlace: Doblón se abrirá y entrarás directamente.');
        }
      } else {
        await auth.signInWithPassword(email: email, password: password);
      }
    } on AuthException catch (error) {
      setState(() => _message = error.statusCode == '400' || error.message.toLowerCase().contains('invalid')
          ? 'El correo o la contraseña no son correctos.'
          : 'No se ha podido completar. Inténtalo de nuevo en unos minutos.');
    } catch (_) {
      setState(() => _message = 'No hay conexión con Doblón. Comprueba internet y vuelve a intentarlo.');
    } finally {
      if (mounted) setState(() => _busy = false);
      _password.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // As on the iPhone: the brand, the drum, «Tu dinero, con calma.», the daily quote and what the bank link can do.
                  Row(children: [
                    ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.asset('assets/don_bigotes.png', width: 52, height: 52, fit: BoxFit.cover)),
                    const SizedBox(width: 12),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Doblón', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                      Text('Finanzas personales', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                    ]),
                  ]),
                  const BomboIllustration(height: 220),
                  const Text('Tu dinero, con calma.', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 14),
                  Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Pulso.heroRadius), side: BorderSide(color: pulso.outline)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('LA FRASE DEL DÍA', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: pulso.accent)),
                        const SizedBox(height: 6),
                        Text(quoteOfTheDay(), style: const TextStyle(fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Icon(Icons.shield_outlined, size: 16, color: Theme.of(context).hintColor),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text('La conexión con tu banco solo lee: nunca puede mover dinero.',
                            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor))),
                  ]),
                  const SizedBox(height: 20),
                  Row(children: [
                    Icon(Icons.lock_outline, size: 14, color: pulso.accent),
                    const SizedBox(width: 6),
                    Text('TU ESPACIO PERSONAL', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: pulso.accent)),
                  ]),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(labelText: 'Correo', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: [_creating ? AutofillHints.newPassword : AutofillHints.password],
                    decoration: InputDecoration(
                        labelText: 'Contraseña', border: const OutlineInputBorder(), helperText: _creating ? passwordRuleText : null, helperMaxLines: 3),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    Text(_message!, style: TextStyle(color: pulso.warning)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0F766E), minimumSize: const Size.fromHeight(52)),
                    child: _busy
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text(_creating ? 'Crear cuenta' : 'Entrar'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _creating = !_creating;
                              _message = null;
                            }),
                    child: Text(_creating ? 'Ya tengo cuenta' : 'Crear una cuenta nueva'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
