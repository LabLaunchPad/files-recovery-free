// engine/recovery_engine.dart — the strict engine boundary (Blueprint Ch. 3).
// The UI layer knows ONLY this interface. Phase 1: SimulatedEngine.
// Phase 2: RustEngine via FFI implementing the exact same contract, so the
// entire UI + test suite runs unchanged against real drive I/O.
library;

import 'dart:async';

import 'error_codes.dart';

export 'error_codes.dart';

enum DeviceKind { sdCard, usbStick, externalDisk, internalDisk, diskImage }

class DeviceInfo {
  final String id, name;
  final int totalBytes;
  final DeviceKind kind;
  final bool mounted;
  final bool isSystemDisk; // locked with explanation, never scannable
  final String? fileSystem;

  /// Where the OS exposes this source to the engine, e.g. `/dev/sdb1`,
  /// `/dev/disk4s1`, `\\.\PhysicalDrive1` — used by destination safety
  /// checks (never recover onto the source). Null on simulated devices.
  final String? sourcePath;

  /// Mount point of the volume when mounted (e.g. `/media/user/USB`),
  /// empty/unset for raw disks without a filesystem mount.
  final String? mountPoint;

  const DeviceInfo({
    required this.id,
    required this.name,
    required this.totalBytes,
    required this.kind,
    required this.mounted,
    this.isSystemDisk = false,
    this.fileSystem,
    this.sourcePath,
    this.mountPoint,
  });

  String get sizeLabel => humanBytes(totalBytes);
}

class SurveyResult {
  final double dataPercent; // % of sampled blocks holding data
  final double unreadablePercent;
  final bool wipePatternDetected;
  final int sampledBlocks;
  const SurveyResult({
    required this.dataPercent,
    required this.unreadablePercent,
    required this.wipePatternDetected,
    this.sampledBlocks = 4096,
  });
}

enum FileState { intact, damaged, fragmented, unreadable }

enum FileKind { photo, raw, video, document, audio, archive, other }

class RecoveredFile {
  final String id, name, relativeFolder;
  final int sizeBytes;
  final FileKind kind;
  final DateTime? capturedAt;
  final FileState state;
  final bool duplicate;
  final int confidencePercent; // carving confidence, drives the badge
  const RecoveredFile({
    required this.id,
    required this.name,
    required this.relativeFolder,
    required this.sizeBytes,
    required this.kind,
    required this.capturedAt,
    required this.state,
    required this.duplicate,
    required this.confidencePercent,
  });
}

enum ScanPhase { ready, running, paused, done, failed, cancelled }

/// Progress event stream contract for backup / scan / recover.
class EngineProgress {
  final int doneBytes, totalBytes;
  final int unreadableAreas;
  final int filesFound; // scan only
  final ScanPhase phase;
  final String? message;
  const EngineProgress({
    required this.doneBytes,
    required this.totalBytes,
    this.unreadableAreas = 0,
    this.filesFound = 0,
    required this.phase,
    this.message,
  });

  double get fraction =>
      totalBytes <= 0 ? 0 : (doneBytes / totalBytes).clamp(0.0, 1.0);
}

/// Typed engine failures so the UI can show precise, calm guidance.
/// [code] classifies the failure (see error_codes.dart); `technical` may
/// carry raw OS text that [classify] already derived the code from.
class EngineException implements Exception {
  final String userMessage; // safe to display verbatim
  final String technical; // for logs
  final FrfErrorCode code;
  const EngineException(this.userMessage,
      [this.technical = '', this.code = FrfErrorCode.unknown]);

  /// Classifies from the raw ABI error code + engine/OS message text.
  factory EngineException.fromEngine(
    String userMessage,
    String technical, {
    int abiCode = frfAbiOk,
  }) =>
      EngineException(userMessage, technical,
          classify(abiCode: abiCode, message: technical));

  @override
  String toString() =>
      'EngineException(${code.wire}, $userMessage, $technical)';
}

/// Result of a completed recovery run: per-file verification evidence.
class RecoveryReceipt {
  final String fileId;
  final String fileName;
  final bool verified;
  final String targetPath;
  const RecoveryReceipt({
    required this.fileId,
    required this.fileName,
    required this.verified,
    required this.targetPath,
  });
}

/// THE engine boundary. Screens and state machine depend on this only.
abstract interface class RecoveryEngine {
  Future<List<DeviceInfo>> listDevices();

  /// Quick sample of the drive: what is realistically recoverable.
  Future<SurveyResult> survey(DeviceInfo device);

  /// Bit-for-bit safety copy. Never writes to the source.
  Stream<EngineProgress> createBackup(DeviceInfo device, Uri destination);

  Stream<EngineProgress> scan(DeviceInfo device, {bool useBackupCopy});

  Future<List<RecoveredFile>> browse(String sessionId);

  /// Writes selected files out. Emits progress, ends with per-file receipts
  /// in [recoveredPaths] (keyed by fileId) once phase == done.
  Stream<EngineProgress> recover(
    String sessionId,
    List<String> fileIds,
    Uri destination, {
    required bool keepFolderStructure,
    required bool byCaptureDate,
  });

  /// Cooperative cancel: running streams end with ScanPhase.cancelled.
  Future<void> cancel();

  /// Optional pause/resume (scan UI button). No-op if unsupported.
  Future<void> pause() async {}
  Future<void> resume() async {}

  /// Per-file verification receipts from the LAST completed recovery.
  /// Engine-sourced evidence — the UI must never fabricate these.
  /// Returns an empty list before the first recovery.
  Future<List<RecoveryReceipt>> receipts();

  /// Free bytes on the volume holding [dir], visible to the current
  /// (unprivileged) user. Returns 0 when unknown — callers degrade to a
  /// warning instead of blocking the flow.
  Future<int> freeBytes(Uri dir);

  /// Human-readable engine identity for the in-app engine badge.
  String get engineName;

  /// Watermark gate: true when this engine produces DEMO data (simulated),
  /// so the UI can label outputs honestly instead of pretending they are
  /// real recoveries.
  bool get isDemo;
}

String humanBytes(num b) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return u == 0
      ? '${b.toInt()} B'
      : '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[u]}';
}
