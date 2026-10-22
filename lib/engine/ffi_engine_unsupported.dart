// engine/ffi_engine_unsupported.dart — web/WASM stand-in.
// dart:ffi does not exist on this platform, so the conditional import in
// ffi_entry.dart selects this file instead of the real FFI engine. The
// app then runs the simulated engine (the WASM/OPFS engine is the
// documented Phase 4 story — see docs/PLATFORMS.md, Web edition).
//
// tryLoad() is always null here, so no member below is ever reachable;
// they exist to satisfy the RecoveryEngine contract at compile time.
library;

import 'recovery_engine.dart';

class FfiRecoveryEngine implements RecoveryEngine {
  FfiRecoveryEngine._();

  /// Always null on the web: callers fall back to the simulated engine.
  static FfiRecoveryEngine? tryLoad() => null;

  Never _unsupported() => throw UnsupportedError(
      'The native carving engine is not available on this platform. '
      'The WASM/OPFS engine is the planned web story (docs/PLATFORMS.md).');

  @override
  Future<List<DeviceInfo>> listDevices() => _unsupported();

  @override
  Future<SurveyResult> survey(DeviceInfo device) => _unsupported();

  @override
  Stream<EngineProgress> createBackup(DeviceInfo device, Uri destination) =>
      _unsupported();

  @override
  Stream<EngineProgress> scan(DeviceInfo device, {bool useBackupCopy = true}) =>
      _unsupported();

  @override
  Future<List<RecoveredFile>> browse(String sessionId) => _unsupported();

  @override
  Stream<EngineProgress> recover(
    String sessionId,
    List<String> fileIds,
    Uri destination, {
    required bool keepFolderStructure,
    required bool byCaptureDate,
  }) =>
      _unsupported();

  @override
  Future<void> cancel() => _unsupported();

  @override
  Future<void> pause() => _unsupported();

  @override
  Future<void> resume() => _unsupported();

  @override
  Future<List<RecoveryReceipt>> receipts() => _unsupported();

  @override
  Future<DeviceInfo> addImageSource(String path) => _unsupported();

  @override
  Future<int> freeBytes(Uri dir) => _unsupported();

  @override
  String get engineName => _unsupported();

  @override
  bool get isDemo => _unsupported();
}
