import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../cloud_privacy.dart';

/// No finance repository, model training or bank refresh starts before keys are ready.
class CloudPrivacyGate extends StatefulWidget {
  const CloudPrivacyGate({super.key, required this.child});
  final Widget child;
  @override
  State<CloudPrivacyGate> createState() => _CloudPrivacyGateState();
}

class _CloudPrivacyGateState extends State<CloudPrivacyGate> {
  late final privacy = CloudPrivacy(Supabase.instance.client);
  final code = TextEditingController();
  CloudCipher? candidate;
  bool ready = false, busy = true, saved = false;
  String? error;
  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await privacy.prepare();
      if (mounted) {
        setState(() {
          ready = value;
          if (!privacy.enrolled) candidate ??= CloudCipher.generate();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'No se ha podido comprobar la protección de esta cuenta. Revisa la conexión o la configuración cloud.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _continue() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (privacy.enrolled) {
        await privacy.unlock(code.text);
      } else {
        await privacy.enroll(candidate!);
      }
      if (mounted) setState(() => ready = true);
    } catch (_) {
      if (mounted) {
        setState(() => error = privacy.enrolled
            ? 'No se han podido desbloquear los datos. Comprueba el código; tus datos no se han modificado.'
            : 'No se ha completado el cifrado. Conserva el código y vuelve a comprobar la conexión antes de reintentar.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ready) return widget.child;
    return Scaffold(
        body: SafeArea(
            child: Center(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Icon(Icons.enhanced_encryption_outlined,
                                size: 48),
                            const SizedBox(height: 20),
                            Text(
                                privacy.enrolled
                                    ? 'Desbloquea tus finanzas'
                                    : 'Protege tus finanzas',
                                style:
                                    Theme.of(context).textTheme.headlineMedium),
                            const SizedBox(height: 16),
                            const Text(
                                'Tus finanzas y lo que aprende tu IA se cifran antes de sincronizarse. La IA trabaja en este dispositivo. El servicio de conexión bancaria procesa los datos al descargarlos del banco.'),
                            const SizedBox(height: 16),
                            const Text(CloudPrivacy.warning),
                            const SizedBox(height: 20),
                            if (privacy.enrolled)
                              TextField(
                                  controller: code,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                      labelText: 'Código de recuperación',
                                      hintText: 'DBL1-…'))
                            else if (candidate != null) ...[
                              const Text('Tu código de recuperación'),
                              const SizedBox(height: 8),
                              SelectableText(candidate!.recoveryCode),
                              CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  value: saved,
                                  onChanged: busy
                                      ? null
                                      : (v) => setState(() => saved = v!),
                                  title: const Text(
                                      'He guardado el código fuera de la app')),
                            ],
                            if (error != null)
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 16),
                                  child: Text(error!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error))),
                            if (busy)
                              const Center(child: CircularProgressIndicator())
                            else if (privacy.profile != null)
                              FilledButton(
                                  onPressed: privacy.enrolled || saved
                                      ? _continue
                                      : null,
                                  child: Text(privacy.enrolled
                                      ? 'Desbloquear'
                                      : 'Cifrar y continuar'))
                            else
                              FilledButton(
                                  onPressed: _prepare,
                                  child: const Text('Volver a comprobar')),
                            TextButton(
                                onPressed: busy ? null : _prepare,
                                child: const Text('Comprobar estado de la protección')),
                            TextButton(
                                onPressed: busy
                                    ? null
                                    : () =>
                                        Supabase.instance.client.auth.signOut(),
                                child: const Text('Salir de la cuenta')),
                          ]),
                    )))));
  }
}
