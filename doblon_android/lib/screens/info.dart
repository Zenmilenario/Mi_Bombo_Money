import 'package:flutter/material.dart';

import '../presentation.dart';
import '../theme.dart';
import 'shell.dart' show DonBigotesMark;
import 'widgets.dart';

/// The version shown in «Acerca de Doblón»; test/info_test.dart checks it against pubspec.yaml.
const appVersion = '0.26.0';

/// Ajustes → Cómo usar la app, as on the iPhone (`AppHelpView`): first steps and important concepts.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    Widget step(int number, String title, String message) => ListTile(
          leading: CircleAvatar(
              radius: 14, backgroundColor: pulso.accent, child: Text('$number', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700))),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(message, style: const TextStyle(fontSize: 12)),
        );
    Widget concept(String title, String value) => ListTile(
          title: Text(title),
          trailing: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 190), child: Text(value, textAlign: TextAlign.right, style: TextStyle(fontSize: 13, color: hint))),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Ayuda', style: TextStyle(fontWeight: FontWeight.w700))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const SectionTitle('Primeros pasos'),
        Card(
          child: Column(children: [
            step(1, 'Añade tus cuentas', 'Registra cada banco, cuenta, tarjeta, efectivo o inversión desde Cuentas, o conecta tu banco en Ajustes › Mis bancos.'),
            step(2, 'Registra movimientos',
                'Pulsa el botón +. Si conectas tu banco, los movimientos llegan solos. Las reglas y la IA reconocen los conceptos habituales.'),
            step(3, 'Define presupuestos', 'Asigna límites mensuales y decide si se repiten y qué hacer con lo que sobra.'),
            step(4, 'Revisa tus objetivos', 'En Presupuestos están tus objetivos de ahorro; el dinero reservado, en Cuentas.'),
          ]),
        ),
        const SectionTitle('Conceptos importantes'),
        Card(
          child: Column(children: [
            concept('Transferencias propias', 'No cuentan como ingreso ni gasto'),
            concept('Saldo de una cuenta', 'Saldo de referencia y movimientos posteriores'),
            concept('Tasa de ahorro', 'Ahorro neto dividido entre ingresos'),
            concept('Pendiente', 'Lo que espera una decisión tuya: movimientos por revisar, coincidencias del banco, aportaciones y traspasos'),
          ]),
        ),
      ]),
    );
  }
}

/// Ajustes → Privacidad y protección de datos, as on the iPhone (`PrivacyInformationView`).
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    Widget row(IconData icon, String title, String message) => ListTile(
          leading: Icon(icon, color: pulso.accent),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(message, style: const TextStyle(fontSize: 13)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Privacidad', style: TextStyle(fontWeight: FontWeight.w700))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: Column(children: [
            row(Icons.wifi_off, 'Funciona sin conexión',
                'Puedes consultar y registrar cambios sin conexión. La sincronización con la nube y las consultas al banco necesitan internet.'),
            row(Icons.key_off_outlined, 'Sin credenciales bancarias',
                'La app no solicita ni guarda contraseñas, PIN ni CVV de tus bancos. Tu cuenta de Doblón es independiente.'),
            row(Icons.face, 'Acceso protegido', 'Puedes bloquear la app al salir y desbloquearla con Face ID, la huella o el código de tu móvil.'),
            row(Icons.cloud_outlined, 'Tus datos, solo tuyos',
                'Cada persona solo puede ver sus propios datos en la nube. Las finanzas de las personas invitadas se cifran en su dispositivo antes de subir.'),
            row(Icons.visibility_off_outlined, 'Importes ocultables', 'El ojo de Inicio oculta cantidades y gráficos cuando necesitas más privacidad.'),
            row(Icons.delete_outline, 'Tu cuenta, cuando quieras', 'En Ajustes puedes exportar una copia de tus datos o eliminar tu cuenta y todos tus datos.'),
          ]),
        ),
        const SectionTitle('Conexión con tus bancos'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
                'Al conectar tus bancos con Enable Banking, autorizas la consulta de cuentas y movimientos desde la web del banco. La app solo lee: nunca puede mover dinero. '
                'Los permisos se guardan cifrados en el servidor y puedes desconectar cada banco desde Mis bancos.',
                style: TextStyle(color: Theme.of(context).hintColor)),
          ),
        ),
      ]),
    );
  }
}

/// Ajustes → Acerca de Doblón, as on the iPhone (`AboutDoblonView`): Don Bigotes, the daily quote and the version.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      appBar: AppBar(title: const Text('Acerca de Doblón', style: TextStyle(fontWeight: FontWeight.w700))),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Pulso.heroRadius),
          child: Semantics(
            label: 'Un gato con traje y corbata señalando, el meme que inspiró a Don Bigotes',
            child: Image.asset('assets/don_bigotes.png', height: 300, width: double.infinity, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(height: 18),
        Row(children: [
          const DonBigotesMark(size: 56),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Don Bigotes', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              Text('Vigila tus cuentas con traje y sin prisas.', style: TextStyle(color: hint)),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        const Text(
            'Se esconde cuando no tiene nada que contar y despierta cuando ve algo tuyo: un cargo retenido, un movimiento por revisar o un recibo que se acerca. '
            'Nunca te dice qué hacer con tu dinero; solo te señala dónde mirar.'),
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
        const SizedBox(height: 10),
        Card(child: ListTile(title: const Text('Versión'), trailing: Text(appVersion, style: TextStyle(color: hint)))),
      ]),
    );
  }
}
