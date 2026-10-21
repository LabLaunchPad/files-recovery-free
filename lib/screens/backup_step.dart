// screens/backup_step.dart — Step 3: safety copy before scanning.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../engine/recovery_engine.dart';
import '../l10n/app_strings.dart';
import '../state/recovery_session.dart';
import '../widgets/core.dart';

class BackupStep extends StatefulWidget {
  final RecoverySession session;
  const BackupStep({super.key, required this.session});

  @override
  State<BackupStep> createState() => _BackupStepState();
}

class _BackupStepState extends State<BackupStep> {
  double _fraction = 0;
  bool _running = false;
  bool _verifying = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  Future<void> _runBackup() async {
    setState(() {
      _running = true;
      _fraction = 0;
    });
    try {
      await for (final p in widget.session.engine.createBackup(
          widget.session.selectedDevice!,
          Uri.file('/tmp/files-recovery-free/backup.img'))) {
        if (!mounted) return;
        setState(() => _fraction = p.fraction);
        if (p.phase == ScanPhase.cancelled) {
          if (mounted) setState(() => _running = false);
          return;
        }
      }
      if (!mounted) return;
      setState(() {
        _verifying = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      widget.session.confirmBackupDone();
    } catch (_) {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
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
                  const StepHeader(2, S.backupTitle, subtitle: S.backupExplainer),
                  const SizedBox(height: FrfSpacing.xl),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(FrfSpacing.l),
                    decoration: BoxDecoration(
                      color: FrfColors.surface,
                      borderRadius: BorderRadius.circular(FrfRadius.card),
                      border: Border.all(color: FrfColors.hairline),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(S.backupDestinationLabel,
                            style: TextStyle(
                                fontSize: FrfType.caption,
                                fontWeight: FontWeight.w700,
                                color: FrfColors.mutedOnLight)),
                        SizedBox(height: FrfSpacing.s),
                        Row(
                          children: [
                            Icon(Icons.folder_rounded,
                                color: FrfColors.brandPrimary),
                            SizedBox(width: FrfSpacing.s),
                            Expanded(
                              child: Text(
                                  '/tmp/files-recovery-free/backup.img',
                                  style: TextStyle(
                                      fontSize: 13.5,
                                      fontFeatures: [],
                                      color: FrfColors.brandDark)),
                            ),
                            GhostCta(S.backupPick, onPressed: null),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: FrfSpacing.xl),
                  if (_running) ...[
                    BlockBar(_fraction),
                    const SizedBox(height: FrfSpacing.m),
                    Text(
                        'Copying… ${(_fraction * 100).round()}% — '
                        '${humanBytes((8.0 * 1024 * 1024 * 1024 * _fraction).round())} of 8.0 GB',
                        style: const TextStyle(
                            fontSize: 13, color: FrfColors.mutedOnLight)),
                    const SizedBox(height: FrfSpacing.m),
                    const DotWave(),
                  ] else if (_verifying) ...[
                    const BlockBar(1.0),
                    const SizedBox(height: FrfSpacing.m),
                    const Text(S.backupDoneLabel,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: FrfColors.ok)),
                  ] else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(FrfSpacing.l),
                      decoration: BoxDecoration(
                        color: FrfColors.rescue.withValues(alpha: 0.1),
                        borderRadius:
                            BorderRadius.circular(FrfRadius.control),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.shield_rounded,
                              color: Color(0xFF7A5205)),
                          const SizedBox(width: FrfSpacing.m),
                          Expanded(
                              child: Text(S.backupSkipWarn,
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: const Color(0xFF7A5205)
                                          .withValues(alpha: 0.9)))),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (!_running)
          WizardActions(
            session: s,
            children: [
              GhostCta(S.backupSkip, onPressed: s.skipBackup),
              const SizedBox(width: FrfSpacing.m),
              PrimaryCta(S.backupDo, onPressed: _runBackup),
            ],
          )
        else
          const SizedBox.shrink(),
      ],
    );
  }
}
