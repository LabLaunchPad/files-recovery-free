// engine/ffi_engine.dart — Phase 2 engine: the Rust carving core behind
// dart:ffi. Implements the EXACT RecoveryEngine contract SimulatedEngine
// implements, so the whole UI + test suite runs unchanged against real
// block-level scanning of disk images (and block devices, when the OS
// permits).
//
// Load order for the dynamic library:
//   1. $FRF_DYLIB_PATH (explicit, used by tests/CI)
//   2. next to the executable (bundled app)
//   3. plain system name (librecovery_core_ffi.so / .dylib / .dll)
//
// Event model: sessions run on Rust worker threads; Dart polls
// frf_session_poll on a short timer and maps events onto the
// EngineProgress stream contract. Engine state is finalized exactly when
// the terminal event is delivered — "Done observed" == "results readable".
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'recovery_engine.dart';

// ------------------------------------------------------------ C structs

final class FrfSourceInfo extends Struct {
  @Array(64)
  external Array<Uint8> id;
  @Array(128)
  external Array<Uint8> name;
  @Uint64()
  external int totalBytes;
  @Uint32()
  external int kind;
  @Uint32()
  external int mounted;
  @Uint32()
  external int isSystem;
  @Array(16)
  external Array<Uint8> fs;
  @Array(512)
  external Array<Uint8> path;
  @Array(256)
  external Array<Uint8> mount;
}

final class FrfSurvey extends Struct {
  @Double()
  external double dataPercent;
  @Double()
  external double unreadablePercent;
  @Uint32()
  external int wipeDetected;
  @Uint32()
  external int sampledBlocks;
}

final class FrfEvent extends Struct {
  @Uint32()
  external int kind; // 0 progress, 1 done, 2 cancelled, 3 error
  @Uint64()
  external int doneBytes;
  @Uint64()
  external int totalBytes;
  @Uint64()
  external int unreadableAreas;
  @Uint64()
  external int filesFound;
  @Int32()
  external int errorCode;
  @Array(256)
  external Array<Uint8> message;
}

final class FrfFile extends Struct {
  @Array(32)
  external Array<Uint8> id;
  @Array(128)
  external Array<Uint8> name;
  @Array(64)
  external Array<Uint8> folder;
  @Uint64()
  external int sizeBytes;
  @Uint32()
  external int kind;
  @Uint32()
  external int state;
  @Int64()
  external int capturedAt;
  @Uint32()
  external int duplicate;
  @Uint32()
  external int confidence;
  @Uint64()
  external int offset;
}

final class FrfReceipt extends Struct {
  @Array(32)
  external Array<Uint8> fileId;
  @Array(128)
  external Array<Uint8> fileName;
  @Uint32()
  external int verified;
  @Array(512)
  external Array<Uint8> targetPath;
}

// ------------------------------------------------------------ bindings

typedef _VersionC = Pointer<Uint8> Function();
typedef _VersionD = Pointer<Uint8> Function();
typedef _LastErrC = Pointer<Uint8> Function();
typedef _LastErrD = Pointer<Uint8> Function();
typedef _SourceRefreshC = Int32 Function();
typedef _SourceRefreshD = int Function();
typedef _SourceCountC = Int32 Function();
typedef _SourceCountD = int Function();
typedef _SourceGetC = Int32 Function(Int32, Pointer<FrfSourceInfo>);
typedef _SourceGetD = int Function(int, Pointer<FrfSourceInfo>);
typedef _AddImageC = Int32 Function(Pointer<Uint8>);
typedef _AddImageD = int Function(Pointer<Uint8>);
typedef _SurveyStartC = Pointer<FrfSurveySession> Function(Pointer<Uint8>);
typedef _SurveyStartD = Pointer<FrfSurveySession> Function(Pointer<Uint8>);
typedef _SurveyPollC = Int32 Function(Pointer<FrfSurveySession>, Pointer<FrfSurvey>);
typedef _SurveyPollD = int Function(Pointer<FrfSurveySession>, Pointer<FrfSurvey>);
typedef _SurveyFreeC = Void Function(Pointer<FrfSurveySession>);
typedef _SurveyFreeD = void Function(Pointer<FrfSurveySession>);
typedef _StartC = Pointer<FrfSession> Function(Pointer<Uint8>, Int32);
typedef _StartD = Pointer<FrfSession> Function(Pointer<Uint8>, int);
typedef _BackupStartC = Pointer<FrfSession> Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _BackupStartD = Pointer<FrfSession> Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _RecoverStartC = Pointer<FrfSession> Function(
    Pointer<Uint8>, Pointer<Uint8>, Int32, Int32);
typedef _RecoverStartD = Pointer<FrfSession> Function(
    Pointer<Uint8>, Pointer<Uint8>, int, int);
typedef _PollC = Int32 Function(Pointer<FrfSession>, Pointer<FrfEvent>);
typedef _PollD = int Function(Pointer<FrfSession>, Pointer<FrfEvent>);
typedef _VoidSessC = Void Function(Pointer<FrfSession>);
typedef _VoidSessD = void Function(Pointer<FrfSession>);
typedef _FinishedC = Int32 Function(Pointer<FrfSession>);
typedef _FinishedD = int Function(Pointer<FrfSession>);
typedef _BrowseCountC = Int32 Function();
typedef _BrowseCountD = int Function();
typedef _BrowseGetC = Int32 Function(Int32, Pointer<FrfFile>);
typedef _BrowseGetD = int Function(int, Pointer<FrfFile>);
typedef _ReceiptCountC = Int32 Function();
typedef _ReceiptCountD = int Function();
typedef _ReceiptGetC = Int32 Function(Int32, Pointer<FrfReceipt>);
typedef _ReceiptGetD = int Function(int, Pointer<FrfReceipt>);
typedef _FreeBytesC = Uint64 Function(Pointer<Uint8>);
typedef _FreeBytesD = int Function(Pointer<Uint8>);

final class FrfSurveySession extends Opaque {}

final class FrfSession extends Opaque {}

// ------------------------------------------------------------ engine

/// Phase 2 engine backed by the Rust carving core. Falls back to nothing:
/// [tryLoad] returns null when the dynamic library is unavailable and the
/// app keeps running on the simulated engine.
class FfiRecoveryEngine implements RecoveryEngine {
  FfiRecoveryEngine._(this._lib, this.version) {
    _lastError = _lib.lookupFunction<_LastErrC, _LastErrD>('frf_last_error');
    _sourceRefresh =
        _lib.lookupFunction<_SourceRefreshC, _SourceRefreshD>('frf_source_refresh');
    _sourceCount =
        _lib.lookupFunction<_SourceCountC, _SourceCountD>('frf_source_count');
    _sourceGet = _lib.lookupFunction<_SourceGetC, _SourceGetD>('frf_source_get');
    _addImage = _lib.lookupFunction<_AddImageC, _AddImageD>('frf_source_add_image');
    _surveyStart =
        _lib.lookupFunction<_SurveyStartC, _SurveyStartD>('frf_survey_start');
    _surveyPoll =
        _lib.lookupFunction<_SurveyPollC, _SurveyPollD>('frf_survey_poll');
    _surveyFree =
        _lib.lookupFunction<_SurveyFreeC, _SurveyFreeD>('frf_survey_free');
    _backupStart =
        _lib.lookupFunction<_BackupStartC, _BackupStartD>('frf_backup_start');
    _scanStart = _lib.lookupFunction<_StartC, _StartD>('frf_scan_start');
    _recoverStart =
        _lib.lookupFunction<_RecoverStartC, _RecoverStartD>('frf_recover_start');
    _sessionPoll = _lib.lookupFunction<_PollC, _PollD>('frf_session_poll');
    _sessionPause = _lib.lookupFunction<_VoidSessC, _VoidSessD>('frf_session_pause');
    _sessionResume =
        _lib.lookupFunction<_VoidSessC, _VoidSessD>('frf_session_resume');
    _sessionCancel =
        _lib.lookupFunction<_VoidSessC, _VoidSessD>('frf_session_cancel');
    _sessionFinished =
        _lib.lookupFunction<_FinishedC, _FinishedD>('frf_session_is_finished');
    _sessionFree = _lib.lookupFunction<_VoidSessC, _VoidSessD>('frf_session_free');
    _browseCount =
        _lib.lookupFunction<_BrowseCountC, _BrowseCountD>('frf_browse_count');
    _browseGet = _lib.lookupFunction<_BrowseGetC, _BrowseGetD>('frf_browse_get');
    _receiptCount = _lib
        .lookupFunction<_ReceiptCountC, _ReceiptCountD>('frf_receipt_count');
    _receiptGet =
        _lib.lookupFunction<_ReceiptGetC, _ReceiptGetD>('frf_receipt_get');
    _freeBytes =
        _lib.lookupFunction<_FreeBytesC, _FreeBytesD>('frf_free_bytes');
  }

  final DynamicLibrary _lib;
  final String version;

  late final _LastErrD _lastError;
  late final _SourceRefreshD _sourceRefresh;
  late final _SourceCountD _sourceCount;
  late final _SourceGetD _sourceGet;
  late final _AddImageD _addImage;
  late final _SurveyStartD _surveyStart;
  late final _SurveyPollD _surveyPoll;
  late final _SurveyFreeD _surveyFree;
  late final _BackupStartD _backupStart;
  late final _StartD _scanStart;
  late final _RecoverStartD _recoverStart;
  late final _PollD _sessionPoll;
  late final _VoidSessD _sessionPause;
  late final _VoidSessD _sessionResume;
  late final _VoidSessD _sessionCancel;
  late final _FinishedD _sessionFinished;
  late final _VoidSessD _sessionFree;
  late final _BrowseCountD _browseCount;
  late final _BrowseGetD _browseGet;
  late final _ReceiptCountD _receiptCount;
  late final _ReceiptGetD _receiptGet;
  late final _FreeBytesD _freeBytes;

  Pointer<FrfEvent>? _eventBuf;
  Pointer<FrfSourceInfo>? _srcBuf;
  Pointer<FrfFile>? _fileBuf;
  Pointer<FrfSurvey>? _surveyBuf;
  Pointer<FrfReceipt>? _receiptBuf;
  Pointer<FrfSession>? _active;

  static FfiRecoveryEngine? tryLoad() {
    const names = {
      'linux': 'librecovery_core_ffi.so',
      'macos': 'librecovery_core_ffi.dylib',
      'windows': 'recovery_core_ffi.dll',
    };
    final candidates = <String>[];
    final env = Platform.environment['FRF_DYLIB_PATH'];
    if (env != null && env.isNotEmpty) candidates.add(env);
    final os = Platform.operatingSystem;
    if (os == 'android') {
      // Phase 3: the engine rides inside the APK as jniLibs; cargo-ndk
      // builds it per ABI and the 16 KB page-size CI assert guarantees
      // Play-compliant load segment alignment.
      return _open(() => DynamicLibrary.open('librecovery_core_ffi.so'));
    }
    if (os == 'ios') {
      // Static-linked engine slice (xcframework) — symbols live in the
      // main executable.
      return _open(() => DynamicLibrary.process());
    }
    if (names.containsKey(os)) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      candidates.add('$exeDir/${names[os]}');
      candidates.add(names[os]!);
    }
    for (final c in candidates) {
      final eng = _open(() => DynamicLibrary.open(c));
      if (eng != null) return eng;
    }
    return null;
  }

  static FfiRecoveryEngine? _open(DynamicLibrary Function() loader) {
    try {
      final lib = loader();
      return FfiRecoveryEngine._(lib, _readVersion(lib));
    } catch (_) {
      return null;
    }
  }

  static String _readVersion(DynamicLibrary lib) {
    try {
      final p = lib
          .lookupFunction<_VersionC, _VersionD>('frf_version')();
      return p.cast<Utf8>().toDartString();
    } catch (_) {
      return 'recovery-ffi';
    }
  }

  // ------------------------------------------------------------- helpers

  String _err() {
    try {
      return _lastError().cast<Utf8>().toDartString();
    } catch (_) {
      return 'unknown engine error';
    }
  }

  String _arrStr(Array<Uint8> a, int max) {
    final sb = StringBuffer();
    for (var i = 0; i < max; i++) {
      final b = a[i];
      if (b == 0) break;
      sb.writeCharCode(b);
    }
    return sb.toString();
  }

  Pointer<Uint8> _cstr(String s) => s.toNativeUtf8().cast<Uint8>();

  void _freeC(Pointer<Uint8> p) => calloc.free(p.cast<Utf8>());

  Pointer<FrfEvent> get _ev {
    _eventBuf ??= calloc<FrfEvent>();
    return _eventBuf!;
  }

  Pointer<FrfSourceInfo> get _src {
    _srcBuf ??= calloc<FrfSourceInfo>();
    return _srcBuf!;
  }

  Pointer<FrfFile> get _file {
    _fileBuf ??= calloc<FrfFile>();
    return _fileBuf!;
  }

  Pointer<FrfSurvey> get _sv {
    _surveyBuf ??= calloc<FrfSurvey>();
    return _surveyBuf!;
  }

  Pointer<FrfReceipt> get _rc {
    _receiptBuf ??= calloc<FrfReceipt>();
    return _receiptBuf!;
  }

  /// Registers one disk image explicitly (tests / drag & drop).
  int registerImage(String path) {
    final p = _cstr(path);
    try {
      final rc = _addImage(p);
      if (rc < 0) {
        throw EngineException.fromEngine(
            'Could not open that image.', _err());
      }
      return rc;
    } finally {
      _freeC(p);
    }
  }

  // ------------------------------------------------------------- devices

  @override
  Future<List<DeviceInfo>> listDevices() async {
    _sourceRefresh();
    final n = _sourceCount();
    final devices = <DeviceInfo>[];
    for (var i = 0; i < n; i++) {
      if (_sourceGet(i, _src) != 0) continue;
      final fs = _arrStr(_src.ref.fs, 16);
      final mount = _arrStr(_src.ref.mount, 256);
      final path = _arrStr(_src.ref.path, 512);
      devices.add(DeviceInfo(
        id: _arrStr(_src.ref.id, 64),
        name: _arrStr(_src.ref.name, 128),
        totalBytes: _src.ref.totalBytes,
        kind: DeviceKind.values[_src.ref.kind.clamp(0, DeviceKind.values.length - 1)],
        mounted: _src.ref.mounted == 1,
        isSystemDisk: _src.ref.isSystem == 1,
        fileSystem: fs.isEmpty ? null : fs,
        sourcePath: path.isEmpty ? null : path,
        mountPoint: mount.isEmpty ? null : mount,
      ));
    }
    return devices;
  }

  /// Free bytes via the engine's frf_free_bytes (statvfs on unix,
  /// GetDiskFreeSpaceExW on Windows). 0 = unknown → callers warn, not block.
  @override
  Future<int> freeBytes(Uri dir) async {
    final p = _cstr(dir.toFilePath());
    try {
      return _freeBytes(p);
    } catch (_) {
      return 0;
    } finally {
      _freeC(p);
    }
  }

  // -------------------------------------------------------------- survey

  @override
  Future<SurveyResult> survey(DeviceInfo device) async {
    final p = _cstr(device.id);
    final ss = _surveyStart(p);
    _freeC(p);
    if (ss == nullptr) {
      throw EngineException.fromEngine('Could not survey this drive.', _err());
    }
    try {
      while (true) {
        final rc = _surveyPoll(ss, _sv);
        if (rc == 1) {
          return SurveyResult(
            dataPercent: _sv.ref.dataPercent,
            unreadablePercent: _sv.ref.unreadablePercent,
            wipePatternDetected: _sv.ref.wipeDetected == 1,
            sampledBlocks: _sv.ref.sampledBlocks,
          );
        }
        if (rc < 0) {
          throw EngineException.fromEngine(
              'Could not survey this drive. Try again.', _err());
        }
        await Future<void>.delayed(const Duration(milliseconds: 6));
      }
    } finally {
      _surveyFree(ss);
    }
  }

  // ------------------------------------------------------------- streams

  Stream<EngineProgress> _pump(Pointer<FrfSession> s, int totalBytes) async* {
    _active = s;
    try {
      while (true) {
        final rc = _sessionPoll(s, _ev);
        if (rc == 1) {
          switch (_ev.ref.kind) {
            case 0:
              yield EngineProgress(
                doneBytes: _ev.ref.doneBytes,
                totalBytes: _ev.ref.totalBytes == 0
                    ? totalBytes
                    : _ev.ref.totalBytes,
                unreadableAreas: _ev.ref.unreadableAreas,
                filesFound: _ev.ref.filesFound,
                phase: ScanPhase.running,
              );
            case 1:
              yield EngineProgress(
                doneBytes: _ev.ref.doneBytes == 0 ? totalBytes : _ev.ref.doneBytes,
                totalBytes: _ev.ref.totalBytes == 0 ? totalBytes : _ev.ref.totalBytes,
                unreadableAreas: _ev.ref.unreadableAreas,
                filesFound: _ev.ref.filesFound,
                phase: ScanPhase.done,
                message: 'Operation complete',
              );
              return;
            case 2:
              yield const EngineProgress(
                  doneBytes: 0, totalBytes: 0, phase: ScanPhase.cancelled);
              return;
            default:
              final msg = _arrStr(_ev.ref.message, 256);
              throw EngineException.fromEngine(
                'The engine hit a problem and stopped.',
                'ffi error ${_ev.ref.errorCode}: $msg',
                abiCode: _ev.ref.errorCode,
              );
          }
        } else if (rc < 0) {
          throw const EngineException(
              'The engine stopped unexpectedly.',
              'ffi: session dead',
              FrfErrorCode.sourceUnreadable);
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 6));
        }
      }
    } finally {
      _active = null;
      _sessionFree(s);
    }
  }

  @override
  Stream<EngineProgress> createBackup(DeviceInfo device, Uri destination) async* {
    final id = _cstr(device.id);
    final dest = _cstr(destination.toFilePath());
    final s = _backupStart(id, dest);
    _freeC(id);
    _freeC(dest);
    if (s == nullptr) {
      throw EngineException.fromEngine(
          'Could not start the backup.', _err());
    }
    yield* _pump(s, device.totalBytes);
  }

  @override
  Stream<EngineProgress> scan(DeviceInfo device, {bool useBackupCopy = true}) async* {
    final id = _cstr(device.id);
    final s = _scanStart(id, useBackupCopy ? 1 : 0);
    _freeC(id);
    if (s == nullptr) {
      throw EngineException.fromEngine('Could not start the scan.', _err());
    }
    yield* _pump(s, device.totalBytes);
  }

  @override
  Future<List<RecoveredFile>> browse(String sessionId) async {
    final n = _browseCount();
    final files = <RecoveredFile>[];
    for (var i = 0; i < n; i++) {
      if (_browseGet(i, _file) != 0) continue;
      final captured = _file.ref.capturedAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(_file.ref.capturedAt * 1000)
          : null;
      files.add(RecoveredFile(
        id: _arrStr(_file.ref.id, 32),
        name: _arrStr(_file.ref.name, 128),
        relativeFolder: _arrStr(_file.ref.folder, 64),
        sizeBytes: _file.ref.sizeBytes,
        kind: FileKind.values[_file.ref.kind.clamp(0, FileKind.values.length - 1)],
        capturedAt: captured,
        state: FileState.values[_file.ref.state.clamp(0, FileState.values.length - 1)],
        duplicate: _file.ref.duplicate == 1,
        confidencePercent: _file.ref.confidence,
      ));
    }
    return files;
  }

  @override
  Stream<EngineProgress> recover(
    String sessionId,
    List<String> fileIds,
    Uri destination, {
    required bool keepFolderStructure,
    required bool byCaptureDate,
  }) async* {
    if (fileIds.isEmpty) {
      throw const EngineException(
          'Nothing selected to recover.', 'empty', FrfErrorCode.invalidArg);
    }
    final csv = _cstr(fileIds.join(','));
    final dest = _cstr(destination.toFilePath());
    final s = _recoverStart(csv, dest, keepFolderStructure ? 1 : 0,
        byCaptureDate ? 1 : 0);
    _freeC(csv);
    _freeC(dest);
    if (s == nullptr) {
      throw EngineException.fromEngine(
          'Could not start the recovery.', _err());
    }
    final total = _pendingBytes(fileIds);
    yield* _pump(s, total);
  }

  int _pendingBytes(List<String> fileIds) {
    var total = 0;
    for (final id in fileIds) {
      final n = _browseCount();
      for (var i = 0; i < n; i++) {
        if (_browseGet(i, _file) != 0) continue;
        if (_arrStr(_file.ref.id, 32) == id) total += _file.ref.sizeBytes;
      }
    }
    return total;
  }

  // ------------------------------------------------------------ receipts

  /// Engine-sourced receipts from the last completed recovery (frf_receipt_*).
  /// This is the real binding: verification evidence comes from the Rust
  /// core that wrote and verified the bytes, never from UI metadata.
  @override
  Future<List<RecoveryReceipt>> receipts() async {
    final n = _receiptCount();
    final out = <RecoveryReceipt>[];
    for (var i = 0; i < n; i++) {
      if (_receiptGet(i, _rc) != 0) continue;
      out.add(RecoveryReceipt(
        fileId: _arrStr(_rc.ref.fileId, 32),
        fileName: _arrStr(_rc.ref.fileName, 128),
        verified: _rc.ref.verified == 1,
        targetPath: _arrStr(_rc.ref.targetPath, 512),
      ));
    }
    return out;
  }

  // ------------------------------------------------------------- identity

  @override
  String get engineName => 'Native carving engine ($version)';

  @override
  bool get isDemo => false;

  // ------------------------------------------------------------- control

  @override
  Future<void> cancel() async {
    final s = _active;
    if (s != null) _sessionCancel(s);
  }

  @override
  Future<void> pause() async {
    final s = _active;
    if (s != null) _sessionPause(s);
  }

  @override
  Future<void> resume() async {
    final s = _active;
    if (s != null) _sessionResume(s);
  }

  /// Diagnostic: whether an operation is mid-flight inside the engine.
  bool get isBusy => _active != null && _sessionFinished(_active!) == 0;
}
