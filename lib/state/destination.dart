// state/destination.dart — real destination picking + safety checks.
// Closes the Phase 3 "no file pickers, /tmp hardcoded" gap (REA ledger).
//
// Ground rules (docs/PLATFORMS.md, ground rule 2): recovered files are
// written ONLY to a user-chosen destination, never to the source. The
// checks here make that rule visible before any bytes are written:
//   1. writability probe (create + delete a dot-file in the folder),
//   2. free-space check via the engine's frf_free_bytes (statvfs /
//      GetDiskFreeSpaceExW — unprivileged, honest unknown handling),
//   3. same-drive-as-source guard — the PhotoRec-grade rule that recovering
//      onto the drive you are recovering FROM risks overwriting what you
//      came to save.
// Pure logic lives in [DestinationSafety]; IO lives in the session so
// everything is unit-testable without rendering.

library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../engine/recovery_engine.dart';

/// The platform folder picker. Injectable for tests (fake selectors).
typedef DirectoryPicker = Future<String?> Function();

/// Default picker: file_selector's native directory dialog on every
/// desktop + Android/iOS (SAF / document picker). Web has no directory
/// concept for this API — callers detect kIsWeb and show the explanatory
/// state instead of invoking the picker.
Future<String?> platformPickDirectory() async {
  if (kIsWeb) return null;
  try {
    return await getDirectoryPath();
  } on Exception {
    // Unsupported platform / user-agent without the API → treated like a
    // cancel by callers; the UI explains instead of pretending.
    return null;
  }
}

/// Result of evaluating a candidate destination directory.
class DestinationCheck {
  /// The evaluated directory (as typed/picked).
  final String dir;

  /// True when the flow may proceed (no blockers).
  final bool ok;

  /// Hard stops: recovering here would endanger data or fail.
  final List<String> blockers;

  /// Proceed-with-care notices.
  final List<String> warnings;

  /// Free bytes reported by the engine (0 = unknown).
  final int freeBytes;

  /// Whether the writability probe ran and what it found.
  final bool probeRan;
  final bool writable;

  /// True when the destination looks like it sits on the source device.
  final bool onSourceDrive;

  const DestinationCheck({
    required this.dir,
    required this.ok,
    required this.blockers,
    required this.warnings,
    required this.freeBytes,
    required this.probeRan,
    required this.writable,
    required this.onSourceDrive,
  });

  const DestinationCheck.unknown(this.dir)
      : ok = true,
        blockers = const [],
        warnings = const [],
        freeBytes = 0,
        probeRan = false,
        writable = false,
        onSourceDrive = false;
}

/// Pure evaluation rules. Inputs are gathered by the caller (session).
abstract final class DestinationSafety {
  /// Headroom over the raw selection size — filesystems reserve slack and
  /// carving confidence can under-report fragmented files.
  static const double spaceHeadroom = 1.10;

  static DestinationCheck evaluate({
    required String dir,
    DeviceInfo? source,
    required int neededBytes,
    required int freeBytes,
    required bool probeRan,
    required bool writable,
  }) {
    final blockers = <String>[];
    final warnings = <String>[];

    final onSource = _onSourceDrive(dir, source);

    if (onSource) {
      blockers.add(
          'That folder is on the drive you are recovering from. Recovering '
          'onto the source can overwrite the very files you came to save — '
          'pick a different drive.');
    }
    if (probeRan && !writable) {
      blockers.add(
          'This folder is not writable. Pick a folder where the app is '
          'allowed to create files.');
    }
    if (freeBytes > 0 && neededBytes > 0) {
      if (freeBytes < neededBytes) {
        blockers.add(
            'Not enough room there: ${humanBytes(neededBytes)} needed, '
            '${humanBytes(freeBytes)} free. Free up space or pick another '
            'drive.');
      } else if (freeBytes < neededBytes * spaceHeadroom) {
        warnings.add(
            'Space is tight: ${humanBytes(freeBytes)} free for '
            '${humanBytes(neededBytes)} of files.');
      }
    }
    if (!probeRan && !kIsWeb && !onSource) {
      warnings.add('Writability could not be verified here — files may '
          'fail mid-way.');
    }

    return DestinationCheck(
      dir: dir,
      ok: blockers.isEmpty,
      blockers: blockers,
      warnings: warnings,
      freeBytes: freeBytes,
      probeRan: probeRan,
      writable: writable,
      onSourceDrive: onSource,
    );
  }

  /// True when [dir] sits on the source device — either inside its OS path
  /// (device node namespace overlap) or inside the volume's mount point.
  static bool _onSourceDrive(String dir, DeviceInfo? source) {
    if (source == null) return false;
    for (final root in [source.mountPoint, source.sourcePath]) {
      if (root == null || root.isEmpty) continue;
      if (isInsideOrEqual(dir, root)) return true;
    }
    return false;
  }

  /// Path-containment test with per-OS separator/case handling.
  /// An empty [root] never matches (defensive: callers pass nullable
  /// device fields directly).
  static bool isInsideOrEqual(String dir, String root) {
    if (root.isEmpty || dir.isEmpty) return false;
    var d = _normalize(dir);
    var r = _normalize(root);
    if (d == r) return true;
    // Device-node prefix match (e.g. destination literally under /dev/...):
    // only meaningful when the root names a real directory tree, so require
    // a separator boundary.
    final sep = Platform.isWindows ? '\\' : '/';
    if (!r.endsWith(sep)) r += sep;
    if (!d.endsWith(sep)) d += sep;
    final sameCase = Platform.isWindows
        ? d.toLowerCase().startsWith(r.toLowerCase())
        : d.startsWith(r);
    return sameCase;
  }

  static String _normalize(String p) {
    var s = p.trim();
    if (Platform.isWindows) s = s.replaceAll('/', '\\');
    // drop trailing separators except the bare root
    final sep = Platform.isWindows ? '\\' : '/';
    while (s.length > 1 && s.endsWith(sep)) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Creates the folder if missing, then probes writability with a
  /// create/delete round-trip. Returns (probeRan, writable).
  static Future<(bool, bool)> probeWritable(String dir) async {
    if (kIsWeb) return (false, false);
    try {
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      final probe = File('${d.path}/.frf_write_probe');
      var ok = false;
      try {
        final f = await probe.create(exclusive: true);
        await f.delete();
        ok = true;
      } on FileSystemException {
        ok = false;
      }
      return (true, ok);
    } on FileSystemException {
      return (true, false);
    }
  }
}

/// Per-OS default destination when the user has not picked one yet.
/// Replaces the old hardcoded `/tmp/files-recovery-free/output` (which was
/// wrong on Windows) while keeping the exact same path on Unix CI/local.
String defaultDestinationRoot() {
  if (Platform.isWindows) {
    final tmp = Platform.environment['TEMP'] ?? r'C:\Temp';
    return '$tmp\\files-recovery-free\\output';
  }
  return '${Directory.systemTemp.path}/files-recovery-free/output';
}

String defaultBackupPath() {
  if (Platform.isWindows) {
    final tmp = Platform.environment['TEMP'] ?? r'C:\Temp';
    return '$tmp\\files-recovery-free\\backup.img';
  }
  return '${Directory.systemTemp.path}/files-recovery-free/backup.img';
}
