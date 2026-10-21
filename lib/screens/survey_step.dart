// screens/survey_step.dart — Step 2: quick sample of the drive.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../l10n/app_strings.dart';
import '../state/recovery_session.dart';
import '../widgets/core.dart';

class SurveyStep extends StatelessWidget {
  final RecoverySession session;
  const SurveyStep({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final s = session;
    final survey = s.surveyResult;
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
                  StepHeader(1, S.surveyTitle,
                      subtitle:
                          '${s.selectedDevice?.name ?? ''} — ${S.stepHints[1]}'),
                  const SizedBox(height: FrfSpacing.xl),
                  if (survey == null)
                    const Center(
                        child: Padding(
                            padding: EdgeInsets.all(FrfSpacing.xxl),
                            child: CircularProgressIndicator()))
                  else ...[
                    Row(
                      children: [
                        Expanded(
                            child: StatCard('${survey.dataPercent.round()}%',
                                S.surveyDataHeld)),
                        const SizedBox(width: FrfSpacing.m),
                        Expanded(
                            child: StatCard(
                                '${survey.unreadablePercent.toStringAsFixed(1)}%',
                                S.surveyUnreadable,
                                valueColor: survey.unreadablePercent > 0
                                    ? FrfColors.warn
                                    : null)),
                      ],
                    ),
                    const SizedBox(height: FrfSpacing.xl),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(FrfSpacing.l),
                      decoration: BoxDecoration(
                        color: FrfColors.surface,
                        borderRadius:
                            BorderRadius.circular(FrfRadius.card),
                        border: Border.all(color: FrfColors.hairline),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SimWatermark(),
                          const SizedBox(height: FrfSpacing.m),
                          DriveMap(survey: survey),
                          const SizedBox(height: FrfSpacing.s),
                          Row(
                            children: [
                              _legend(FrfColors.blockData, 'data'),
                              const SizedBox(width: FrfSpacing.l),
                              _legend(FrfColors.blockUnreadable,
                                  S.surveyUnreadable.toLowerCase()),
                              const SizedBox(width: FrfSpacing.l),
                              _legend(FrfColors.blockEmpty, 'empty'),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: FrfSpacing.xl),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(FrfSpacing.l),
                      decoration: BoxDecoration(
                        color: survey.wipePatternDetected
                            ? FrfColors.bad.withValues(alpha: 0.08)
                            : FrfColors.ok.withValues(alpha: 0.08),
                        borderRadius:
                            BorderRadius.circular(FrfRadius.card),
                      ),
                      child: Row(
                        children: [
                          Icon(
                              survey.wipePatternDetected
                                  ? Icons.warning_amber_rounded
                                  : Icons.verified_rounded,
                              color: survey.wipePatternDetected
                                  ? FrfColors.bad
                                  : FrfColors.ok),
                          const SizedBox(width: FrfSpacing.m),
                          Expanded(
                            child: Text(
                                survey.wipePatternDetected
                                    ? S.surveyWipeYes
                                    : S.surveyVerdictGood,
                                style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: survey.wipePatternDetected
                                        ? FrfColors.bad
                                        : const Color(0xFF1B6B3C))),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        WizardActions(
          session: session,
          children: [
            PrimaryCta(S.surveyCta,
                onPressed: survey == null ? null : session.goBackup),
          ],
        ),
      ],
    );
  }

  Widget _legend(Color c, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
                color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(
                fontSize: 11.5, color: FrfColors.mutedOnLight)),
      ],
    );
  }
}
