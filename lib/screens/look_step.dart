// screens/look_step.dart — Step 5: browse, filter and select found files.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../engine/recovery_engine.dart';
import '../l10n/app_strings.dart';
import '../state/recovery_session.dart';
import '../widgets/core.dart';
import 'license_sheet.dart';

class LookStep extends StatelessWidget {
  final RecoverySession session;
  const LookStep({super.key, required this.session});

  String _kindLabel(FileKind k) {
    switch (k) {
      case FileKind.photo:
        return 'Photos';
      case FileKind.raw:
        return 'RAW';
      case FileKind.video:
        return 'Videos';
      case FileKind.document:
        return 'Documents';
      case FileKind.audio:
        return 'Audio';
      case FileKind.archive:
        return 'Archives';
      case FileKind.other:
        return 'Other';
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = session;
    final files = s.visibleFiles;
    final overCap = s.needsUpgradeForSelection;
    // The whole step is ONE scroll view: header + filters + selection bar +
    // file rows. Short viewports (phone landscape) simply scroll instead of
    // overflowing — guarded by the golden matrix.
    return Column(
      children: [
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(
                    FrfSpacing.xl, FrfSpacing.l, FrfSpacing.xl,
                    FrfSpacing.l),
                itemCount: files.length + 2,
                itemBuilder: (context, i) {
                  if (i == 0) return _header(context, s);
                  if (i == 1) {
                    return files.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.symmetric(
                                vertical: FrfSpacing.xl),
                            child: Text(S.lookEmpty,
                                style: TextStyle(
                                    color: FrfColors.mutedOnLight)),
                          )
                        : _selectionBar(s);
                  }
                  final f = files[i - 2];
                  return _FileRow(file: f, session: s);
                },
              ),
            ),
          ),
        ),
        WizardActions(
          session: session,
          children: [
            const Text(S.lookFreeNotice,
                style: TextStyle(
                    fontSize: 12.5, color: FrfColors.mutedOnLight)),
            const SizedBox(width: FrfSpacing.m),
            if (overCap)
              FilledButton.tonal(
                onPressed: () => showLicenseSheet(context, s),
                style: FilledButton.styleFrom(
                    backgroundColor: FrfColors.rescue,
                    foregroundColor: const Color(0xFF3D2A00)),
                child: const Text(S.lookUpgrade,
                    style: TextStyle(fontWeight: FontWeight.w800)),
              )
            else
              PrimaryCta(S.lookContinue,
                  onPressed:
                      s.selectedCount == 0 ? null : s.startRecovery),
          ],
        ),
      ],
    );
  }

  Widget _header(BuildContext context, RecoverySession s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: FrfSpacing.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StepHeader(4, S.lookTitle,
              subtitle:
                  '${s.foundFiles.length} ${S.scanFound} — select what you need'),
          const SizedBox(height: FrfSpacing.m),
          TextField(
            onChanged: (v) => s.applyFilter((f) => f.query = v),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              hintText: S.lookSearch,
              border: OutlineInputBorder(
                  borderRadius:
                      BorderRadius.circular(FrfRadius.control)),
            ),
          ),
          const SizedBox(height: FrfSpacing.m),
          Wrap(
            spacing: FrfSpacing.m,
            runSpacing: FrfSpacing.s,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownMenu<FileKind?>(
                width: 150,
                initialSelection: s.filter.kind,
                dropdownMenuEntries: [
                  const DropdownMenuEntry(
                      value: null, label: S.lookAllKinds),
                  ...FileKind.values.map((k) =>
                      DropdownMenuEntry(value: k, label: _kindLabel(k))),
                ],
                onSelected: (v) => s.applyFilter((f) => f.kind = v),
              ),
              FilterChip(
                label: const Text(S.lookHideDuplicates),
                selected: s.filter.hideDuplicates,
                onSelected: (v) =>
                    s.applyFilter((f) => f.hideDuplicates = v),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _selectionBar(RecoverySession s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: FrfSpacing.s),
      child: Row(
        children: [
          TextButton(
              onPressed: s.selectAllVisible,
              child: const Text(S.lookSelectAll)),
          TextButton(
              onPressed: s.clearSelection,
              child: const Text(S.lookClear)),
          const Spacer(),
          Text(
              '${s.selectedCount} ${S.lookSelected} · ${humanBytes(s.selectedBytes)}',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: FrfColors.brandDark)),
        ],
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  final RecoveredFile file;
  final RecoverySession session;
  const _FileRow({required this.file, required this.session});

  IconData get _icon {
    switch (file.kind) {
      case FileKind.photo:
        return Icons.image_rounded;
      case FileKind.raw:
        return Icons.camera_alt_rounded;
      case FileKind.video:
        return Icons.videocam_rounded;
      case FileKind.document:
        return Icons.description_rounded;
      case FileKind.audio:
        return Icons.graphic_eq_rounded;
      case FileKind.archive:
        return Icons.folder_zip_rounded;
      case FileKind.other:
        return Icons.insert_drive_file_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = session.selectedFileIds.contains(file.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: FrfSpacing.s),
      child: Material(
        color: selected
            ? FrfColors.brandPrimary.withValues(alpha: 0.07)
            : FrfColors.surface,
        borderRadius: BorderRadius.circular(FrfRadius.control),
        child: InkWell(
          borderRadius: BorderRadius.circular(FrfRadius.control),
          onTap: () => session.toggleSelect(file.id),
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: FrfSpacing.m, vertical: FrfSpacing.s),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(FrfRadius.control),
              border: Border.all(
                  color: selected
                      ? FrfColors.brandPrimary
                      : FrfColors.hairline),
            ),
            child: Row(
              children: [
                Icon(_icon,
                    size: 22,
                    color: file.state == FileState.unreadable
                        ? FrfColors.locked
                        : FrfColors.brandBright),
                const SizedBox(width: FrfSpacing.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(file.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: FrfColors.brandDark)),
                      Text(
                          '${file.relativeFolder} · '
                          '${file.capturedAt?.toIso8601String().substring(0, 10) ?? '—'} · '
                          '${humanBytes(file.sizeBytes)} · ${file.confidencePercent}%',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11.5,
                              color: FrfColors.mutedOnLight)),
                    ],
                  ),
                ),
                FileBadge(FileBadge.labelForState(file.state),
                    tone: FileBadge.toneForState(file.state)),
                if (file.duplicate) ...[
                  const SizedBox(width: FrfSpacing.s),
                  const FileBadge(S.badgeDuplicate, tone: BadgeTone.muted),
                ],
                const SizedBox(width: FrfSpacing.s),
                Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: selected
                        ? FrfColors.brandPrimary
                        : FrfColors.locked),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
