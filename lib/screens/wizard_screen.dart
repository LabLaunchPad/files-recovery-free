// screens/wizard_screen.dart — adaptive 6-step wizard shell.
// Desktop/tablet: left rail with step list. Phone: compact top dots + bottom
// actions. Flavor adjusts accents (Cupertino on macOS/iOS, Fluent-inspired
// desktop, Material 3 elsewhere) without forking the layout.
library;

import 'package:flutter/material.dart';

import '../app_brand.dart';
import '../design/tokens.dart';
import '../l10n/app_strings.dart';
import '../state/recovery_session.dart';
import '../widgets/core.dart';
import 'backup_step.dart';
import 'choose_step.dart';
import 'license_sheet.dart';
import 'look_step.dart';
import 'recover_step.dart';
import 'scan_step.dart';
import 'survey_step.dart';

class WizardScreen extends StatefulWidget {
  final RecoverySession session;
  const WizardScreen({super.key, required this.session});

  @override
  State<WizardScreen> createState() => _WizardScreenState();
}

class _WizardScreenState extends State<WizardScreen> {
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.session.refreshDevices();
    });
  }

  @override
  void didUpdateWidget(covariant WizardScreen old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_onChange);
      widget.session.addListener(_onChange);
    }
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    // Wide (rail) layout needs width AND height: landscape phones fall back
    // to the compact top-dots layout (phone-portrait goldens guard this).
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 700 && size.height >= 500;
    return Scaffold(
      backgroundColor: FrfColors.canvas,
      appBar: _brandBar(context, s),
      body: SafeArea(
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _RailStepper(session: s),
                  const VerticalDivider(width: 1, color: FrfColors.hairline),
                  Expanded(child: _content(context, s)),
                ],
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: FrfSpacing.l, vertical: FrfSpacing.m),
                    child: StepDots(current: s.step.index),
                  ),
                  Expanded(child: _content(context, s)),
                ],
              ),
      ),
    );
  }

  PreferredSizeWidget _brandBar(BuildContext context, RecoverySession s) {
    return AppBar(
      backgroundColor: FrfColors.brandDark,
      foregroundColor: FrfColors.onDark,
      titleSpacing: FrfSpacing.l,
      title: Row(
        children: [
          _logoMark(),
          const SizedBox(width: FrfSpacing.m),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(AppBrand.storeDisplayName,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: FrfColors.onDark)),
              Text(AppBrand.tagline,
                  style: TextStyle(
                      fontSize: 10.5,
                      color: FrfColors.onDark.withValues(alpha: 0.7))),
            ],
          ),
        ],
      ),
      actions: [
        if (!s.licensed)
          Padding(
            padding: const EdgeInsets.only(right: FrfSpacing.l),
            child: FilledButton.tonal(
              onPressed: () => showLicenseSheet(context, s),
              style: FilledButton.styleFrom(
                backgroundColor: FrfColors.rescue,
                foregroundColor: const Color(0xFF3D2A00),
              ),
              child: const Text('Pro ${AppBrand.proPrice}',
                  style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          )
        else
          const Padding(
            padding: EdgeInsets.only(right: FrfSpacing.l),
            child: Chip(
              avatar: Icon(Icons.workspace_premium,
                  size: 16, color: FrfColors.rescue),
              label: Text('Pro',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              backgroundColor: FrfColors.onDark,
            ),
          ),
      ],
    );
  }

  Widget _logoMark() {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [FrfColors.brandBright, FrfColors.brandPrimary]),
        borderRadius: BorderRadius.circular(9),
      ),
      child: const Icon(Icons.restore_from_trash_rounded,
          size: 19, color: Colors.white),
    );
  }

  Widget _content(BuildContext context, RecoverySession s) {
    final s0 = s;
    switch (s0.step) {
      case WizardStep.choose:
        return ChooseStep(session: s0);
      case WizardStep.survey:
        return SurveyStep(session: s0);
      case WizardStep.backup:
        return BackupStep(session: s0);
      case WizardStep.scan:
        return ScanStep(session: s0);
      case WizardStep.look:
        return LookStep(session: s0);
      case WizardStep.recover:
        return RecoverStep(session: s0);
    }
  }
}

// -------------------------------------------------------------- rail (wide)
class _RailStepper extends StatelessWidget {
  final RecoverySession session;
  const _RailStepper({required this.session});

  @override
  Widget build(BuildContext context) {
    final s = session;
    return Container(
      width: 230,
      color: FrfColors.surface,
      padding: const EdgeInsets.all(FrfSpacing.xl),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(S.steps.length, (i) {
          final done = i < s.step.index;
          final active = i == s.step.index;
          return Padding(
            padding: const EdgeInsets.only(bottom: FrfSpacing.l),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done
                        ? FrfColors.brandPrimary
                        : (active ? FrfColors.brandDark : FrfColors.blockEmpty),
                  ),
                  child: done
                      ? const Icon(Icons.check_rounded,
                          size: 15, color: Colors.white)
                      : Text('${i + 1}',
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: active
                                  ? Colors.white
                                  : FrfColors.mutedOnLight)),
                ),
                const SizedBox(width: FrfSpacing.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(S.steps[i],
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: active
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                              color: active
                                  ? FrfColors.brandDark
                                  : FrfColors.mutedOnLight)),
                      Text(S.stepHints[i],
                          style: TextStyle(
                              fontSize: 10.5,
                              color: FrfColors.mutedOnLight
                                  .withValues(alpha: 0.8))),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
        ),
      ),
    );
  }
}

