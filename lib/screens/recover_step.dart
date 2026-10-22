// screens/recover_step.dart — Step 6: write files out + verification receipt.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../engine/recovery_engine.dart';
import '../l10n/app_strings.dart';
import '../state/recovery_session.dart';
import '../widgets/core.dart';

class RecoverStep extends StatelessWidget {
  final RecoverySession session;
  const RecoverStep({super.key, required this.session});

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
              child: _body(context, s),
            ),
          ),
        ),
        _actions(context, s),
      ],
    );
  }

  Widget _body(BuildContext context, RecoverySession s) {
    if (s.recoverPhase == RecoverPhase.done) return _done(context, s);
    if (s.recoverPhase == RecoverPhase.cancelled) {
      return const Column(children: [
        StepHeader(5, S.recoverCancelled),
        SizedBox(height: FrfSpacing.xl),
        Icon(Icons.info_outline_rounded,
            size: 42, color: FrfColors.locked),
      ]);
    }
    if (s.recoverPhase == RecoverPhase.running) return _running(s);
    return _configure(context, s);
  }

  Widget _configure(BuildContext context, RecoverySession s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StepHeader(5, S.recoverTitle,
            subtitle:
                '${s.selectedCount} files · ${humanBytes(s.selectedBytes)}'),
        const SizedBox(height: FrfSpacing.xl),
        const _OptionTile(
            title: S.recoverKeepFolders, value: true, onChanged: null),
        const _OptionTile(title: S.recoverByDate, value: false, onChanged: null),
        const SizedBox(height: FrfSpacing.l),
        _destinationCard(context, s),
      ],
    );
  }

  Widget _destinationCard(BuildContext context, RecoverySession s) {
    if (kIsWeb) {
      return _cardShell(const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(S.recoverDestination,
              style: TextStyle(
                  fontSize: FrfType.caption,
                  fontWeight: FontWeight.w700,
                  color: FrfColors.mutedOnLight)),
          SizedBox(height: FrfSpacing.s),
          Icon(Icons.cloud_download_outlined, color: FrfColors.brandPrimary),
          SizedBox(width: FrfSpacing.s),
          Text(S.recoverDestWeb, style: TextStyle(fontSize: 13.5)),
        ],
      ));
    }
    final check = s.destinationCheck;
    final dir = s.effectiveDestination;
    return _cardShell(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(S.recoverDestination,
            style: TextStyle(
                fontSize: FrfType.caption,
                fontWeight: FontWeight.w700,
                color: FrfColors.mutedOnLight)),
        const SizedBox(height: FrfSpacing.s),
        Row(children: [
          const Icon(Icons.folder_open_rounded, color: FrfColors.brandPrimary),
          const SizedBox(width: FrfSpacing.s),
          Expanded(
            child: Text(
                dir + (s.destinationChosen ? '' : '  ·  ${S.recoverDestDefault}'),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5)),
          ),
          const SizedBox(width: FrfSpacing.s),
          GhostCta(S.recoverPickFolder, onPressed: s.busy ? null : s.chooseDestination),
        ]),
        const SizedBox(height: FrfSpacing.s),
        if (s.destinationChecking)
          const Row(children: [
            SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: FrfSpacing.s),
            Text(S.recoverDestChecking, style: TextStyle(fontSize: 12.5)),
          ])
        else if (check != null) ...[
          Wrap(spacing: FrfSpacing.s, runSpacing: FrfSpacing.s, children: [
            if (check.onSourceDrive)
              _chip(S.recoverDestOnSource, bad: true)
            else if (check.probeRan)
              _chip(check.writable ? S.recoverDestWritable : S.recoverDestNotWritable,
                  bad: !check.writable, good: check.writable),
            if (check.freeBytes > 0)
              _chip(
                  '${humanBytes(check.freeBytes)} ${S.recoverDestFree}',
                  good: check.freeBytes >= s.selectedBytes),
            if (check.freeBytes == 0) _chip(S.recoverDestSpaceUnknown),
          ]),
          for (final w in check.warnings)
            Padding(
              padding: const EdgeInsets.only(top: FrfSpacing.s),
              child: Row(children: [
                const Icon(Icons.info_outline_rounded,
                    size: 15, color: FrfColors.warn),
                const SizedBox(width: FrfSpacing.s),
                Expanded(
                    child: Text(w,
                        style: const TextStyle(fontSize: 12.5))),
              ]),
            ),
        ],
      ],
    ));
  }

  Widget _cardShell(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(FrfSpacing.l),
        decoration: BoxDecoration(
          color: FrfColors.surface,
          borderRadius: BorderRadius.circular(FrfRadius.card),
          border: Border.all(color: FrfColors.hairline),
        ),
        child: child,
      );

  Widget _chip(String label, {bool bad = false, bool good = false}) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: FrfSpacing.s, vertical: 3),
        decoration: BoxDecoration(
          color: bad
              ? FrfColors.bad.withValues(alpha: 0.1)
              : good
                  ? FrfColors.ok.withValues(alpha: 0.1)
                  : FrfColors.hairline.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(FrfRadius.control),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: bad
                    ? FrfColors.bad
                    : good
                        ? FrfColors.ok
                        : FrfColors.mutedOnLight)),
      );

  Widget _running(RecoverySession s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const StepHeader(5, S.recoverTitle),
        const SizedBox(height: FrfSpacing.xl),
        BlockBar(s.progressFraction),
        const SizedBox(height: FrfSpacing.m),
        Row(children: [
          Expanded(
              child: StatCard('${(s.progressFraction * 100).round()}%',
                  'written')),
          const SizedBox(width: FrfSpacing.m),
          Expanded(
              child: StatCard('${s.selectedCount}',
                  S.recoverDoneSummary.toLowerCase())),
        ]),
        const SizedBox(height: FrfSpacing.xl),
        const DotWave(),
      ],
    );
  }

  Widget _done(BuildContext context, RecoverySession s) {
    final verified = s.receipts.where((r) => r.verified).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(children: [
          Icon(Icons.verified_rounded,
              color: FrfColors.ok, size: 34),
          SizedBox(width: FrfSpacing.m),
          Expanded(
              child: Text(S.recoverDoneTitle,
                  style: TextStyle(
                      fontSize: FrfType.display,
                      fontWeight: FontWeight.w800,
                      color: FrfColors.brandDark))),
        ]),
        const SizedBox(height: FrfSpacing.s),
        Text(
            '${s.receipts.length} ${S.recoverDoneSummary} — '
            '$verified ${S.recoverVerified}, '
            '${s.receipts.length - verified} ${S.recoverNotVerified}',
            style: const TextStyle(
                fontSize: FrfType.body, color: FrfColors.mutedOnLight)),
        const SizedBox(height: FrfSpacing.s),
        EngineBadge(
            engineName: s.engine.engineName, isDemo: s.engine.isDemo),
        const SizedBox(height: FrfSpacing.xl),
        ...s.receipts.take(12).map((r) => Padding(
              padding: const EdgeInsets.only(bottom: FrfSpacing.s),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: FrfSpacing.m, vertical: FrfSpacing.s),
                decoration: BoxDecoration(
                  color: FrfColors.surface,
                  borderRadius: BorderRadius.circular(FrfRadius.control),
                  border: Border.all(color: FrfColors.hairline),
                ),
                child: Row(children: [
                  Icon(
                      r.verified
                          ? Icons.check_circle_rounded
                          : Icons.help_outline_rounded,
                      size: 18,
                      color: r.verified
                          ? FrfColors.ok
                          : FrfColors.warn),
                  const SizedBox(width: FrfSpacing.s),
                  Expanded(
                      child: Text(r.targetPath,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12))),
                ]),
              ),
            )),
      ],
    );
  }

  Widget _actions(BuildContext context, RecoverySession s) {
    final List<Widget> kids;
    switch (s.recoverPhase) {
      case RecoverPhase.done:
        kids = [
          GhostCta(S.recoverAgain,
              onPressed: () {
                s.clearSelection();
                s.openLook();
              }),
          const SizedBox(width: FrfSpacing.m),
          PrimaryCta(S.recoverStartOver, onPressed: s.reset),
        ];
        break;
      case RecoverPhase.running:
        kids = [
          GhostCta(S.recoverCancel,
              onPressed: s.cancelOperation, color: FrfColors.bad),
        ];
        break;
      case RecoverPhase.cancelled:
        kids = [PrimaryCta(S.recoverStartOver, onPressed: s.reset)];
        break;
      case RecoverPhase.configure:
        kids = [
          PrimaryCta(S.recoverStart,
              onPressed: s.selectedCount == 0 || s.busy
                  ? null
                  : () => s.startRecovery()),
        ];
        break;
    }
    return WizardActions(session: s, children: kids);
  }
}

class _OptionTile extends StatelessWidget {
  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  const _OptionTile(
      {required this.title, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: FrfSpacing.s),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: FrfSpacing.m, vertical: FrfSpacing.s),
        decoration: BoxDecoration(
          color: FrfColors.surface,
          borderRadius: BorderRadius.circular(FrfRadius.control),
          border: Border.all(color: FrfColors.hairline),
        ),
        child: Row(children: [
          Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 13.5, color: FrfColors.brandDark))),
          Switch(value: value, onChanged: onChanged),
        ]),
      ),
    );
  }
}
