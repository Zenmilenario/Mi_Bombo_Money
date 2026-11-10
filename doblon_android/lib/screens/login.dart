import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../presentation.dart';
import '../theme.dart';

/// Sign-in with the same Doblón account as on the iPhone. No financial data before signing in:
/// only the brand and a daily curiosity.
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
    if (email.isEmpty || password.length < 8) {
      setState(() => _message = 'Escribe tu correo y una contraseña de al menos 8 caracteres.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final auth = Supabase.instance.client.auth;
    try {
      if (_creating) {
        final response = await auth.signUp(email: email, password: password);
        if (response.session == null && mounted) {
          setState(() => _message = 'Te hemos enviado un correo. Confirma tu cuenta y vuelve aquí para entrar.');
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
                  ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: Image.asset('assets/don_bigotes.png', height: 140, fit: BoxFit.cover),
                  ),
                  const SizedBox(height: 20),
                  Text('Doblón', textAlign: TextAlign.center, style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text('Tu dinero, en claro.', textAlign: TextAlign.center, style: TextStyle(color: pulso.accent, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 20),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        Icon(Icons.auto_stories_outlined, color: pulso.accent),
                        const SizedBox(width: 12),
                        Expanded(child: Text(quoteOfTheDay(), style: Theme.of(context).textTheme.bodyMedium)),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 24),
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
                    decoration: const InputDecoration(labelText: 'Contraseña', border: OutlineInputBorder()),
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
