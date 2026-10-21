// widgets/core.dart — the shared component library (Blueprint Ch. 6).
// Every screen composes from here so the golden matrix can guard the
// components once and the screens inherit the guard.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../engine/recovery_engine.dart';
import '../l10n/app_strings.dart';
import '../state/recovery_session.dart';

// ------------------------------------------------------------------ badges
enum BadgeTone { ok, warn, bad, muted }

class FileBadge extends StatelessWidget {
  final String label;
  final BadgeTone tone;
  const FileBadge(this.label, {super.key, required this.tone});

  static BadgeTone toneForState(FileState s) {
    switch (s) {
      case FileState.intact:
        return BadgeTone.ok;
      case FileState.damaged:
        return BadgeTone.warn;
      case FileState.fragmented:
        return BadgeTone.muted;
      case FileState.unreadable:
        return BadgeTone.bad;
    }
  }

  static String labelForState(FileState s) {
    switch (s) {
      case FileState.intact:
        return S.badgeIntact;
      case FileState.damaged:
        return S.badgeDamaged;
      case FileState.fragmented:
        return S.badgeFragmented;
      case FileState.unreadable:
        return S.badgeUnreadable;
    }
  }

  Color get _fg {
    switch (tone) {
      case BadgeTone.ok:
        return FrfColors.ok;
      case BadgeTone.warn:
        return const Color(0xFF9A6206);
      case BadgeTone.bad:
        return FrfColors.bad;
      case BadgeTone.muted:
        return FrfColors.mutedOnLight;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _fg.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: _fg)),
    );
  }
}

// --------------------------------------------------------------- step dots
class StepDots extends StatelessWidget {
  final int current; // 0..5
  const StepDots({super.key, required this.current});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(S.steps.length * 2 - 1, (i) {
        if (i.isOdd) {
          final beforeConnector = i ~/ 2;
          return Expanded(
            child: Container(
              height: 2,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              color: beforeConnector < current
                  ? FrfColors.brandPrimary
                  : FrfColors.hairline,
            ),
          );
        }
        final idx = i ~/ 2;
        final done = idx < current;
        final active = idx == current;
        return AnimatedContainer(
          duration: FrfMotion.standard,
          width: active ? 26 : 10,
          height: 10,
          decoration: BoxDecoration(
            color: done || active
                ? FrfColors.brandPrimary
                : FrfColors.hairline,
            borderRadius: BorderRadius.circular(999),
          ),
        );
      }),
    );
  }
}

// ---------------------------------------------------------------- drive map
/// Heatmap of sampled blocks: what fraction holds data / is unreadable.
class DriveMap extends StatelessWidget {
  final SurveyResult survey;
  final int blocks;
  const DriveMap({super.key, required this.survey, this.blocks = 400});

  List<Color> get _cells {
    final r = math.Random(7); // stable pattern for goldens
    final data = survey.dataPercent / 100;
    final bad = survey.unreadablePercent / 100;
    return List.generate(blocks, (i) {
      final v = r.nextDouble();
      if (v < bad) return FrfColors.blockUnreadable;
      if (v < bad + data) return FrfColors.blockData;
      return FrfColors.blockEmpty;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cells = _cells;
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      children: [
        for (final c in cells)
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- block bar
/// Deterministic-looking progress bar made of blocks (scan/backup/recover).
class BlockBar extends StatelessWidget {
  final double fraction; // 0..1
  final int segments;
  final bool paused;
  const BlockBar(this.fraction,
      {super.key, this.segments = 32, this.paused = false});

  @override
  Widget build(BuildContext context) {
    final filled = (fraction.clamp(0.0, 1.0) * segments).round();
    return Row(
      children: List.generate(segments, (i) {
        final isFilled = i < filled;
        final isHead = i == filled - 1 && fraction < 1;
        return Expanded(
          child: Container(
            height: 14,
            margin: const EdgeInsets.symmetric(horizontal: 1.5),
            decoration: BoxDecoration(
              color: isFilled
                  ? (isHead && paused
                      ? FrfColors.rescue
                      : FrfColors.brandPrimary)
                  : FrfColors.blockEmpty,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        );
      }),
    );
  }
}

// ----------------------------------------------------------------- dot wave
/// Live "working" animation used on the scan step.
class DotWave extends StatefulWidget {
  final Color color;
  const DotWave({super.key, this.color = FrfColors.brandPrimary});

  @override
  State<DotWave> createState() => _DotWaveState();
}

class _DotWaveState extends State<DotWave>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respect the platform "reduce motion" setting: render a static wave.
    // This also makes golden tests deterministic.
    if (MediaQuery.disableAnimationsOf(context)) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(7, (i) {
          final dy = math.sin(i / 7 * math.pi) * 6;
          return Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            transform: Matrix4.translationValues(0, -dy, 0),
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: 0.35 + 0.65 * (i / 7)),
              shape: BoxShape.circle,
            ),
          );
        }),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(7, (i) {
            final t = (_c.value * 2 + i * 0.18) % 1.0;
            final dy = math.sin(t * math.pi) * 6;
            return Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              transform: Matrix4.translationValues(0, -dy, 0),
              decoration: BoxDecoration(
                color: widget.color.withValues(
                    alpha: 0.35 + 0.65 * math.sin(t * math.pi).abs()),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}

// --------------------------------------------------------------- watermark
class SimWatermark extends StatelessWidget {
  const SimWatermark({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: FrfColors.warn.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: FrfColors.warn),
      ),
      child: const Text(S.scanWatermark,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFF7A5205))),
    );
  }
}

// --------------------------------------------------------------- stat card
class StatCard extends StatelessWidget {
  final String value;
  final String label;
  final Color? valueColor;
  const StatCard(this.value, this.label, {super.key, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(FrfSpacing.l),
      decoration: BoxDecoration(
        color: FrfColors.surface,
        borderRadius: BorderRadius.circular(FrfRadius.card),
        border: Border.all(color: FrfColors.hairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: FrfType.stat,
                  fontWeight: FontWeight.w700,
                  color: valueColor ?? FrfColors.brandDark)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  fontSize: FrfType.caption,
                  color: FrfColors.mutedOnLight)),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- step header
class StepHeader extends StatelessWidget {
  final int stepIndex;
  final String title;
  final String? subtitle;
  const StepHeader(this.stepIndex, this.title, {super.key, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step ${stepIndex + 1} of ${S.steps.length} — ${S.steps[stepIndex]}',
            style: const TextStyle(
                fontSize: FrfType.caption,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: FrfColors.brandBright)),
        const SizedBox(height: FrfSpacing.xs),
        Text(title,
            style: const TextStyle(
                fontSize: FrfType.display,
                fontWeight: FontWeight.w800,
                color: FrfColors.brandDark)),
        if (subtitle != null) ...[
          const SizedBox(height: FrfSpacing.xs),
          Text(subtitle!,
              style: const TextStyle(
                  fontSize: FrfType.body,
                  color: FrfColors.mutedOnLight)),
        ],
      ],
    );
  }
}

// ----------------------------------------------------------------- buttons
class PrimaryCta extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool destructive;
  const PrimaryCta(this.label, {super.key, this.onPressed, this.destructive = false});

  @override
  Widget build(BuildContext context) {
    final bg = destructive ? FrfColors.bad : FrfColors.brandPrimary;
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: Colors.white,
        padding:
            const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(FrfRadius.control)),
      ),
      child: Text(label,
          style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}

class GhostCta extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Color color;
  const GhostCta(this.label, {super.key, this.onPressed, this.color = FrfColors.brandBright});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.5)),
        padding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(FrfRadius.control)),
      ),
      child: Text(label),
    );
  }
}

/// Bottom action bar used by individual steps for consistent CTA placement.
class WizardActions extends StatelessWidget {
  final RecoverySession session;
  final List<Widget> children;
  const WizardActions({super.key, required this.session, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(FrfSpacing.l),
      decoration: const BoxDecoration(
        color: FrfColors.surface,
        border: Border(top: BorderSide(color: FrfColors.hairline)),
      ),
      // Wrap instead of Row: action CTAs must never overflow on narrow
      // viewports (caught by the phone-portrait golden tests).
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: FrfSpacing.m,
        runSpacing: FrfSpacing.s,
        children: [
          if (session.canGoBack)
            GhostCta('Back', onPressed: session.back),
          ...children,
        ],
      ),
    );
  }
}
