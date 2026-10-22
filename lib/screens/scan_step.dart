// screens/scan_step.dart — Step 4: deep scan with live progress.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../l10n/app_strings.dart';
import '../state/recovery_session.dart';
import '../widgets/core.dart';

class ScanStep extends StatelessWidget {
  final RecoverySession session;
  const ScanStep({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final s = session;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(FrfSpacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StepHeader(3, '${S.scanTitle} — ${s.selectedDevice?.name ?? ''}'),
                  const SizedBox(height: FrfSpacing.xs),
                  Text(
                      s.backupDone
                          ? S.scanFromCopy
                          : S.scanFromOriginal,
                      style: const TextStyle(
                          fontSize: FrfType.body,
                          color: FrfColors.mutedOnLight)),
                  const SizedBox(height: FrfSpacing.xl),
                  BlockBar(s.progressFraction),
                  const SizedBox(height: FrfSpacing.m),
                  Row(
                    children: [
                      Expanded(
                          child: StatCard('${s.filesFound}', S.scanFound)),
                      const SizedBox(width: FrfSpacing.m),
                      Expanded(
                          child: StatCard('${s.unreadableAreas}',
                              S.scanUnreadable,
                              valueColor: s.unreadableAreas > 0
                                  ? FrfColors.warn
                                  : null)),
                      const SizedBox(width: FrfSpacing.m),
                      Expanded(
                          child: StatCard(
                              '${(s.progressFraction * 100).round()}%',
                              'of the drive')),
                    ],
                  ),
                  const SizedBox(height: FrfSpacing.xl),
                  const DotWave(),
                  const SizedBox(height: FrfSpacing.xl),
                  if (session.engine.isDemo) const Center(child: SimWatermark()),
                  if (s.errorText != null) ...[
                    const SizedBox(height: FrfSpacing.xl),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(FrfSpacing.l),
                      decoration: BoxDecoration(
                        color: FrfColors.bad.withValues(alpha: 0.08),
                        borderRadius:
                            BorderRadius.circular(FrfRadius.control),
                      ),
                      child: Text(s.errorText!,
                          style: const TextStyle(
                              fontSize: 13, color: FrfColors.bad)),
                    ),
                    const SizedBox(height: FrfSpacing.m),
                    Center(
                        child: GhostCta(S.backupDo,
                            onPressed: s.goBackup)),
                  ],
                ],
              ),
            ),
          ),
        ),
        WizardActions(
          session: s,
          children: [
            GhostCta(S.scanCancel,
                onPressed: s.busy ? s.cancelOperation : null,
                color: FrfColors.bad),
          ],
        ),
      ],
    );
  }
}
