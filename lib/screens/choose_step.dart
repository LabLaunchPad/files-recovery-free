// screens/choose_step.dart — Step 1: pick the source drive.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../engine/recovery_engine.dart';
import '../l10n/app_strings.dart';
import '../state/recovery_session.dart';
import '../widgets/core.dart';

class ChooseStep extends StatelessWidget {
  final RecoverySession session;
  const ChooseStep({super.key, required this.session});

  IconData _iconFor(DeviceKind k) {
    switch (k) {
      case DeviceKind.sdCard:
        return Icons.sd_card_rounded;
      case DeviceKind.usbStick:
        return Icons.usb_rounded;
      case DeviceKind.externalDisk:
        return Icons.save_rounded;
      case DeviceKind.internalDisk:
        return Icons.storage_rounded;
      case DeviceKind.diskImage:
        return Icons.album_rounded;
    }
  }

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
                  const StepHeader(0, S.chooseTitle, subtitle: S.chooseSubtitle),
                  const SizedBox(height: FrfSpacing.m),
                  EngineBadge(
                      engineName: s.engine.engineName,
                      isDemo: s.engine.isDemo),
                  if (s.errorText != null) ...[
                    const SizedBox(height: FrfSpacing.m),
                    _ErrorBar(text: s.errorText!, hint: s.errorHint),
                  ],
                  const SizedBox(height: FrfSpacing.xl),
                  if (s.busy && s.devices.isEmpty)
                    const Center(
                        child: Padding(
                            padding: EdgeInsets.all(FrfSpacing.xxl),
                            child: CircularProgressIndicator()))
                  else
                    ...s.devices.map((d) => _DeviceCard(
                          device: d,
                          selected: s.selectedDevice?.id == d.id,
                          onTap: () => s.selectDevice(d.id),
                          icon: _iconFor(d.kind),
                        )),
                ],
              ),
            ),
          ),
        ),
        WizardActions(
          session: session,
          children: [
            GhostCta(S.chooseRefresh,
                onPressed: s.busy ? null : s.refreshDevices),
            const SizedBox(width: FrfSpacing.m),
            PrimaryCta(S.chooseContinue,
                onPressed: s.selectedDevice == null || s.busy
                    ? null
                    : s.runSurvey),
          ],
        ),
      ],
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final DeviceInfo device;
  final bool selected;
  final VoidCallback? onTap;
  final IconData icon;
  const _DeviceCard(
      {required this.device,
      required this.selected,
      required this.onTap,
      required this.icon});

  @override
  Widget build(BuildContext context) {
    final locked = device.isSystemDisk;
    final disabled = locked || onTap == null;
    return Opacity(
      opacity: locked ? 0.72 : 1,
      child: Padding(
        padding: const EdgeInsets.only(bottom: FrfSpacing.m),
        child: Material(
          color: selected ? FrfColors.brandPrimary.withValues(alpha: 0.06) : FrfColors.surface,
          borderRadius: BorderRadius.circular(FrfRadius.card),
          child: InkWell(
            borderRadius: BorderRadius.circular(FrfRadius.card),
            onTap: disabled ? null : onTap,
            child: Container(
              padding: const EdgeInsets.all(FrfSpacing.l),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(FrfRadius.card),
                border: Border.all(
                    color: selected ? FrfColors.brandPrimary : FrfColors.hairline,
                    width: selected ? 2 : 1),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: FrfColors.blockEmpty,
                      borderRadius: BorderRadius.circular(FrfRadius.control),
                    ),
                    child: Icon(icon,
                        color: locked ? FrfColors.locked : FrfColors.brandPrimary,
                        size: 24),
                  ),
                  const SizedBox(width: FrfSpacing.l),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(device.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: FrfColors.brandDark)),
                            ),
                            if (device.fileSystem != null) ...[
                              const SizedBox(width: FrfSpacing.s),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: FrfColors.blockEmpty,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(device.fileSystem!,
                                    style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: FrfColors.mutedOnLight)),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          locked
                              ? S.chooseSystemLocked
                              : (device.mounted
                                  ? '${device.sizeLabel} · mounted'
                                  : '${device.sizeLabel} · ${S.chooseNotMounted}'),
                          style: TextStyle(
                              fontSize: 12.5,
                              color: locked
                                  ? FrfColors.locked
                                  : FrfColors.mutedOnLight),
                        ),
                      ],
                    ),
                  ),
                  if (locked)
                    const Icon(Icons.lock_rounded,
                        color: FrfColors.locked, size: 20)
                  else
                    Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: selected
                            ? FrfColors.brandPrimary
                            : FrfColors.locked),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  final String text;
  final String? hint;
  const _ErrorBar({required this.text, this.hint});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(FrfSpacing.m),
      decoration: BoxDecoration(
        color: FrfColors.bad.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(FrfRadius.control),
        border: Border.all(color: FrfColors.bad.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              color: FrfColors.bad, size: 18),
          const SizedBox(width: FrfSpacing.s),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(text,
                    style: const TextStyle(
                        fontSize: 13, color: FrfColors.bad)),
                if (hint != null) ...[
                  const SizedBox(height: 4),
                  Text(hint!,
                      style: const TextStyle(
                          fontSize: 12, color: FrfColors.mutedOnLight)),
                ],
              ])),
        ],
      ),
    );
  }
}
