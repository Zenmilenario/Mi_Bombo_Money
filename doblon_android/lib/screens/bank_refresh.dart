// Refreshing the banks from Don Bigotes: he thinks while it runs (also on his floating button after closing the
// panel), the panel says the real phase, and at the end one line says how it went, bank by bank.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../bank_sync.dart';
import '../data.dart';
import '../theme.dart';
import 'shell.dart' show DonBigotesMark;

/// Three dots that rise in turn while Don Bigotes works. Still, when the system asks for fewer animations.
class ThinkingDots extends StatefulWidget {
  const ThinkingDots({super.key, this.size = 6, this.color});
  final double size;
  final Color? color;

  @override
  State<ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<ThinkingDots> with SingleTickerProviderStateMixin {
  late final controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.stop();
    } else if (!controller.isAnimating) {
      controller.repeat();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Pulso.of(context).accent;
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < 3; i++)
            Builder(builder: (context) {
              // Each dot rises during its third of the cycle.
              final phase = ((controller.value * 3) - i).clamp(0.0, 1.0);
              final lift = controller.isAnimating ? (phase < 0.5 ? phase : 1 - phase) * 2 : 0.0;
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: widget.size * 0.25),
                child: Transform.translate(
                  offset: Offset(0, -lift * widget.size * 0.7),
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(color: color.withValues(alpha: 0.45 + 0.55 * lift), shape: BoxShape.circle),
                  ),
                ),
              );
            }),
        ]),
      ),
    );
  }
}

/// The refresh part of Don Bigotes' panel: the button, the phase while it runs and the result when it ends. It
/// reads the repository, so closing and reopening the panel shows the real state.
class BankRefreshPanel extends StatelessWidget {
  const BankRefreshPanel({super.key, required this.repository});
  final FinanceRepository repository;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([repository.bankProgress, repository]),
        builder: (context, _) {
          final pulso = Pulso.of(context);
          final hint = Theme.of(context).hintColor;
          final progress = repository.bankProgress.value;
          final result = repository.bankResult;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FilledButton.icon(
              // While it runs, pressing again does nothing: the refresh in progress is the one that counts.
              onPressed: progress != null ? null : () => repository.synchronizeBanks(manual: true),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
              icon: progress != null ? const ThinkingDots(color: Colors.white) : const Icon(Icons.refresh),
              label: Text(progress != null ? 'Consultando tus bancos…' : 'Actualizar mis bancos'),
            ),
            if (progress != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Semantics(
                  liveRegion: true,
                  child: Row(children: [
                    const DonBigotesMark(size: 30, mood: CompanionMood.thinking),
                    const SizedBox(width: 10),
                    Expanded(child: Text(progress.text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                  ]),
                ),
              )
            else if (result != null)
              _Result(result: result, admin: repository.isAdministrator, pulso: pulso, hint: hint),
            const SizedBox(height: 12),
          ]);
        },
      );
}

class _Result extends StatelessWidget {
  const _Result({required this.result, required this.admin, required this.pulso, required this.hint});
  final BankSyncResult result;
  final bool admin;
  final Pulso pulso;
  final Color hint;

  @override
  Widget build(BuildContext context) {
    final time = DateFormat('HH:mm').format(result.finishedAt);
    final failed = result.errors.entries.where((e) => !result.updatedBanks.contains(e.key)).toList();
    final color = switch (result.outcome) {
      BankSyncOutcome.updated || BankSyncOutcome.noChanges => pulso.income,
      BankSyncOutcome.partial || BankSyncOutcome.waiting => pulso.warning,
      BankSyncOutcome.failed => pulso.expense,
      BankSyncOutcome.nothing => hint,
    };
    final icon = switch (result.outcome) {
      BankSyncOutcome.updated || BankSyncOutcome.noChanges => Icons.check_circle_outline,
      BankSyncOutcome.failed => Icons.error_outline,
      _ => Icons.info_outline,
    };
    String seconds(int ms) => '${(ms / 1000).toStringAsFixed(1).replaceAll('.', ',')} s';
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: pulso.tertiary, borderRadius: BorderRadius.circular(Pulso.compactRadius)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Expanded(child: Text(result.headline, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
            Text(time, style: TextStyle(fontSize: 12, color: hint)),
          ]),
          if (result.reviews > 0) Text('${result.reviews} por revisar', style: TextStyle(fontSize: 12, color: hint)),
          if (result.updatedBanks.isNotEmpty) Text('Actualizados: ${result.updatedBanks.join(', ')}', style: const TextStyle(fontSize: 12)),
          for (final e in failed) Text('${e.key}: ${e.value}', style: TextStyle(fontSize: 12, color: pulso.expense)),
          for (final e in result.waiting.entries)
            Text('${e.key}: se podrá consultar a las ${DateFormat('HH:mm').format(e.value)}', style: TextStyle(fontSize: 12, color: hint)),
          // Where the time goes, for the developer's account: phases and banks only, no amounts.
          if (admin && result.timings.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Tiempos: ${result.timings.entries.map((e) => '${e.key} ${seconds(e.value)}').join(' · ')}',
                  style: TextStyle(fontSize: 11, color: hint)),
            ),
        ]),
      ),
    );
  }
}
