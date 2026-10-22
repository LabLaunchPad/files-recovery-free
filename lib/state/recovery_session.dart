// state/recovery_session.dart — wizard state machine (Blueprint Ch. 5).
// Pure Dart: unit-testable without rendering. All engine calls are guarded;
// failures land in [errorText] instead of crashing the wizard, and every
// stream subscription is cancelled on reset/dispose (no leaks).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_brand.dart';
import '../engine/recovery_engine.dart';
import '../engine/simulated_engine.dart';
import 'destination.dart';
import 'image_import.dart';
import 'license_store.dart';

enum WizardStep { choose, survey, backup, scan, look, recover }

/// Recovery phase inside the final step.
enum RecoverPhase { configure, running, done, cancelled }

class LookFilter {
  FileKind? kind;
  FileState? state;
  String query = '';
  bool hideDuplicates = false;
  void clear() {
    kind = null;
    state = null;
    query = '';
    hideDuplicates = false;
  }
}

class RecoverySession extends ChangeNotifier {
  final RecoveryEngine engine;

  WizardStep _step = WizardStep.choose;
  WizardStep get step => _step;

  List<DeviceInfo> devices = [];
  DeviceInfo? selectedDevice;
  SurveyResult? surveyResult;
  bool backupDone = false;

  bool busy = false; // guards double-taps on every async action
  int filesFound = 0;
  double progressFraction = 0;
  int unreadableAreas = 0;
  List<RecoveredFile> foundFiles = [];
  final Set<String> selectedFileIds = {};
  final LookFilter filter = LookFilter();

  bool licensed = false; // free tier gates recovery; scanning stays free

  /// True when [licensed] came from an Ed25519-SIGNED key (a real
  /// purchase). Dev keys accepted by the simulated engine stay false.
  bool licenseSigned = false;

  /// The key currently activated (normalized), persisted when signed.
  String? licenseKey;
  RecoverPhase recoverPhase = RecoverPhase.configure;
  final List<RecoveryReceipt> receipts = [];
  String? errorText;

  // ------------------------------------------------------------- destination
  /// Where recovered files are written. Null = the per-OS default still
  /// applies; the Recover step always shows which one is in effect.
  String? destinationPath;

  /// True once the user explicitly picked a folder this session.
  bool destinationChosen = false;

  /// Latest evaluation of [effectiveDestination], refreshed on pick and
  /// right before a recovery starts. Null = not evaluated yet.
  DestinationCheck? destinationCheck;

  /// True while the writability/space probe is in flight.
  bool destinationChecking = false;

  /// The folder picker (file_selector on real platforms; faked in tests).
  DirectoryPicker pickDirectory = platformPickDirectory;

  /// The disk-image file picker + SAF bridge (faked in tests).
  ImageFilePicker pickImageFile = platformPickImageFile;
  SafBridge safBridge = SafBridge();

  /// True while a disk-image import (pick → ingest → register) is running.
  bool importingImage = false;

  /// Writability-probe switch. Tests/CI set false to keep widget tests
  /// deterministic (the probe does real file IO that fake async never
  /// delivers). Real runs always probe.
  bool destinationProbeEnabled = true;

  /// Path in effect right now (explicit pick or per-OS default).
  String get effectiveDestination => destinationPath ?? defaultDestinationRoot();

  Uri get destinationUri => Uri.file(effectiveDestination);

  /// Opens the native folder dialog; user-cancel keeps the previous state.
  Future<void> chooseDestination() async {
    final picked = await pickDirectory();
    if (picked == null || picked.isEmpty) return;
    await setDestination(picked);
  }

  /// Evaluates a candidate destination (probe + space + source guard).
  Future<void> setDestination(String dir) async {
    destinationPath = dir;
    destinationChosen = true;
    destinationChecking = true;
    _safeNotify();
    destinationCheck = await _evaluateDestination(dir);
    destinationChecking = false;
    _safeNotify();
  }

  Future<DestinationCheck> _evaluateDestination(String dir) async {
    final (probeRan, writable) = destinationProbeEnabled
        ? await DestinationSafety.probeWritable(dir)
        : (false, false);
    int free = 0;
    try {
      free = await engine.freeBytes(Uri.file(dir));
    } catch (_) {
      free = 0; // unknown → warn, never fabricate
    }
    return DestinationSafety.evaluate(
      dir: dir,
      source: selectedDevice,
      neededBytes: selectedBytes,
      freeBytes: free,
      probeRan: probeRan,
      writable: writable,
    );
  }

  /// Classified failure code for the last error (null when fine). Screens
  /// use it plus [errorHint] for OS-specific remediation guidance.
  FrfErrorCode? errorCode;

  /// OS-specific remediation for [errorCode], or null.
  String? get errorHint {
    final c = errorCode;
    if (c == null || c == FrfErrorCode.none) return null;
    return remediationFor(c, os: Platform.operatingSystem);
  }

  StreamSubscription<EngineProgress>? _sub;
  bool _disposed = false;

  RecoverySession({RecoveryEngine? engine, this.licenseStore})
      : engine = engine ?? SimulatedEngine();

  /// Where the Pro key persists across restarts (shared_preferences on
  /// real builds, in-memory in tests). Null = no persistence.
  final LicenseStore? licenseStore;

  /// Restores a persisted signed key at startup. Stale keys that no
  /// longer verify (foreign engine build, expired trial) are dropped.
  Future<void> restoreLicense() async {
    final store = licenseStore;
    if (store == null) return;
    final String? saved;
    try {
      saved = await store.load();
    } catch (_) {
      return; // persistence unavailable — run unlicensed, never crash
    }
    if (saved == null || saved.isEmpty) return;
    final v = await engine.verifyLicense(saved);
    if (v.valid) {
      licensed = true;
      licenseSigned = v.signed;
      licenseKey = saved;
      _safeNotify();
    } else {
      try {
        await store.clear();
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------- derived
  bool get canGoBack => _step != WizardStep.choose && !busy;
  List<RecoveredFile> get visibleFiles {
    Iterable<RecoveredFile> f = foundFiles;
    if (filter.kind != null) f = f.where((x) => x.kind == filter.kind);
    if (filter.state != null) f = f.where((x) => x.state == filter.state);
    if (filter.hideDuplicates) f = f.where((x) => !x.duplicate);
    if (filter.query.isNotEmpty) {
      final q = filter.query.toLowerCase();
      f = f.where((x) =>
          x.name.toLowerCase().contains(q) ||
          x.relativeFolder.toLowerCase().contains(q));
    }
    return f.toList();
  }

  int get selectedCount => selectedFileIds.length;
  int get selectedBytes => foundFiles
      .where((f) => selectedFileIds.contains(f.id))
      .fold(0, (a, f) => a + f.sizeBytes);
  bool get needsUpgradeForSelection =>
      !licensed && FreeTier.needsUpgrade(selectedCount);

  // -------------------------------------------------------------- choose
  Future<void> refreshDevices() async {
    errorText = null;
    errorCode = null;
    busy = true;
    notifyListeners();
    try {
      devices = await engine.listDevices();
    } on EngineException catch (e) {
      _fail(e.userMessage, technical: 'devices: $e', code: e.code);
    } catch (e) {
      _fail('Could not list drives. Try again.', technical: 'devices: $e');
    } finally {
      busy = false;
      _safeNotify();
    }
  }

  bool selectDevice(String id) {
    final matches = devices.where((x) => x.id == id).toList();
    if (matches.isEmpty) return false;
    final d = matches.first;
    if (d.isSystemDisk) return false; // locked with explanation (spec 5.1)
    selectedDevice = d;
    notifyListeners();
    return true;
  }

  /// Choose → "Import a disk image": pick a file, route Android
  /// `content://` URIs through SAF ingestion into the app cache, register
  /// with the engine, refresh the list and select the new source. User
  /// cancel is a no-op; failures land in [errorText]/[errorCode].
  Future<void> importDiskImage() async {
    if (busy || importingImage) return;
    importingImage = true;
    errorText = null;
    errorCode = null;
    _safeNotify();
    try {
      final picked = await pickImageFile();
      if (picked == null || picked.isEmpty) return;
      var path = picked;
      if (safBridge.shouldIngest(path)) {
        path = await safBridge.ingestToCache(path);
      }
      final device = await engine.addImageSource(path);
      await refreshDevices();
      final match = devices.where((d) => d.id == device.id).toList();
      selectedDevice = match.isNotEmpty ? match.first : device;
    } on EngineException catch (e) {
      _fail(e.userMessage, technical: 'import-image: $e', code: e.code);
    } catch (e) {
      _fail(SafBridge.ingestFailed,
          technical: 'import-image: $e', code: FrfErrorCode.invalidSource);
    } finally {
      importingImage = false;
      _safeNotify();
    }
  }

  // -------------------------------------------------------------- survey
  Future<void> runSurvey() async {
    if (selectedDevice == null || busy) return;
    _step = WizardStep.survey;
    busy = true;
    errorText = null;
    errorCode = null;
    notifyListeners();
    try {
      surveyResult = await engine.survey(selectedDevice!);
    } on EngineException catch (e) {
      _fail(e.userMessage, technical: 'survey: $e', code: e.code);
    } catch (e) {
      _fail('Could not survey this drive. Try again.', technical: 'survey: $e');
    } finally {
      busy = false;
      _safeNotify();
    }
  }

  void goBackup() {
    _step = WizardStep.backup;
    notifyListeners();
  }

  // -------------------------------------------------------------- backup
  void skipBackup() => startScan(useBackupCopy: false);

  void confirmBackupDone() {
    backupDone = true;
    startScan(useBackupCopy: true);
  }

  // ---------------------------------------------------------------- scan
  void startScan({required bool useBackupCopy}) {
    if (selectedDevice == null) return;
    _step = WizardStep.scan;
    filesFound = 0;
    progressFraction = 0;
    unreadableAreas = 0;
    busy = true;
    errorText = null;
    errorCode = null;
    foundFiles = [];
    notifyListeners();
    _sub?.cancel();
    _sub = engine
        .scan(selectedDevice!, useBackupCopy: useBackupCopy)
        .listen(_onScanEvent,
            onError: (Object e) => _fail('The scan hit a problem and stopped.',
                    technical: 'scan-error: $e',
                    code: _codeOf(e)));
  }

  void _onScanEvent(EngineProgress p) {
    filesFound = p.filesFound;
    progressFraction = p.fraction;
    unreadableAreas = p.unreadableAreas;
    switch (p.phase) {
      case ScanPhase.done:
        busy = false;
        _loadResults();
        break;
      case ScanPhase.failed:
        _fail(
            'The scan stopped. If the drive is failing, make a backup first '
            'next time.',
            code: FrfErrorCode.sourceUnreadable);
        break;
      case ScanPhase.cancelled:
        busy = false;
        errorText = null;
        _step = WizardStep.backup; // let the user choose a safer path
        _safeNotify();
        break;
      default:
        _safeNotify();
    }
  }

  Future<void> _loadResults() async {
    try {
      foundFiles = await engine.browse('session');
      selectedFileIds.clear();
      _step = WizardStep.look;
    } on EngineException catch (e) {
      _fail('Found files could not be listed. Try scanning again.',
          technical: 'browse: $e',
          code: e.code);
      return;
    } catch (e) {
      _fail('Found files could not be listed. Try scanning again.',
          technical: 'browse: $e');
      return;
    }
    _safeNotify();
  }

  // ---------------------------------------------------------------- look
  void openLook() {
    _step = WizardStep.look;
    notifyListeners();
  }

  void toggleSelect(String fileId) {
    selectedFileIds.contains(fileId)
        ? selectedFileIds.remove(fileId)
        : selectedFileIds.add(fileId);
    notifyListeners();
  }

  void selectAllVisible() {
    selectedFileIds.addAll(visibleFiles.map((f) => f.id));
    notifyListeners();
  }

  void clearSelection() {
    selectedFileIds.clear();
    notifyListeners();
  }

  void applyFilter(void Function(LookFilter) mutate) {
    mutate(filter);
    notifyListeners();
  }

  // ------------------------------------------------------------- license
  /// Activates a Pro key via the ENGINE (never a local regex — real
  /// engines verify the Ed25519 signature, the simulated engine accepts
  /// dev-format keys). Signed keys are persisted for next launch.
  Future<bool> activateLicense(String key) async {
    final v = await engine.verifyLicense(key);
    if (!v.valid) return false;
    licensed = true;
    licenseSigned = v.signed;
    licenseKey = key.trim();
    if (v.signed && licenseStore != null) {
      try {
        await licenseStore!.save(licenseKey!);
      } catch (_) {
        // persistence is best-effort; the unlock stays active this run
      }
    }
    notifyListeners();
    return true;
  }

  // ------------------------------------------------------------- recover
  /// Look → Recover: open the CONFIGURE phase (destination card + options)
  /// instead of jumping straight into writing. The Recover step's own
  /// Start button then runs [startRecovery] with the safety net.
  void openRecoverConfigure() {
    if (selectedFileIds.isEmpty || needsUpgradeForSelection) return;
    _step = WizardStep.recover;
    recoverPhase = RecoverPhase.configure;
    errorText = null;
    errorCode = null;
    notifyListeners();
    _refreshDestinationCheck();
  }

  /// Re-evaluates the destination in effect without changing the phase.
  Future<void> _refreshDestinationCheck() async {
    destinationChecking = true;
    _safeNotify();
    destinationCheck = await _evaluateDestination(effectiveDestination);
    destinationChecking = false;
    _safeNotify();
  }

  Future<void> startRecovery() async {
    if (selectedFileIds.isEmpty || needsUpgradeForSelection || busy) return;
    recoverPhase = RecoverPhase.running;
    _step = WizardStep.recover;
    progressFraction = 0;
    busy = true;
    errorText = null;
    errorCode = null;
    receipts.clear();
    notifyListeners();

    // Destination safety net: evaluate the folder in effect (also covers a
    // folder whose files changed since the last check) and refuse to write
    // when a blocker applies. Failures land as typed errors + UI hint.
    final dir = effectiveDestination;
    final check = await _evaluateDestination(dir);
    destinationCheck = check;
    if (!check.ok) {
      _fail(check.blockers.first,
          technical: 'destination: ${check.blockers.join(' | ')}',
          code: check.freeBytes > 0 && check.freeBytes < selectedBytes
              ? FrfErrorCode.destinationFull
              : FrfErrorCode.destinationInvalid);
      recoverPhase = RecoverPhase.configure;
      return;
    }

    _sub?.cancel();
    _sub = engine
        .recover('session', selectedFileIds.toList(), Uri.file(dir),
            keepFolderStructure: true, byCaptureDate: false)
        .listen(_onRecoverEvent,
            onError: (Object e) => _fail(
                'Recovery stopped before finishing. Your files were not '
                'changed.',
                technical: 'recover-error: $e',
                code: _codeOf(e)));
  }

  void _onRecoverEvent(EngineProgress p) {
    progressFraction = p.fraction;
    switch (p.phase) {
      case ScanPhase.done:
        busy = false;
        recoverPhase = RecoverPhase.done;
        // Receipts come from the ENGINE (per-file verification evidence),
        // never from scan metadata. REA gap fix: frf_receipt_* is now the
        // single source of truth for the receipt screen.
        _loadReceipts();
        break;
      case ScanPhase.cancelled:
        busy = false;
        recoverPhase = RecoverPhase.cancelled;
        break;
      case ScanPhase.failed:
        _fail('Recovery stopped before finishing. Your files were not '
            'changed.');
        return;
      default:
        break;
    }
    _safeNotify();
  }

  Future<void> _loadReceipts() async {
    try {
      final r = await engine.receipts();
      if (_disposed || recoverPhase != RecoverPhase.done) return;
      receipts
        ..clear()
        ..addAll(r);
      _safeNotify();
    } catch (e) {
      // Honest degradation: show zero receipts rather than fabricate any.
      debugPrint('RecoverySession: engine receipts unavailable: $e');
    }
  }

  Future<void> cancelOperation() async {
    await engine.cancel();
  }

  // ------------------------------------------------------------ navigation
  void back() {
    if (!canGoBack) return;
    _step = WizardStep.values[_step.index - 1];
    errorText = null;
    notifyListeners();
  }

  void reset() {
    _sub?.cancel();
    _step = WizardStep.choose;
    selectedFileIds.clear();
    foundFiles = [];
    filesFound = 0;
    progressFraction = 0;
    unreadableAreas = 0;
    surveyResult = null;
    backupDone = false;
    errorText = null;
    errorCode = null;
    busy = false;
    recoverPhase = RecoverPhase.configure;
    receipts.clear();
    filter.clear();
    _resetDestination();
    notifyListeners();
  }

  /// Destination resets with the wizard: a new session gets a fresh choice.
  void _resetDestination() {
    destinationPath = null;
    destinationChosen = false;
    destinationCheck = null;
    destinationChecking = false;
  }

  // -------------------------------------------------------------- internal
  void _fail(String userMessage, {String? technical, FrfErrorCode? code}) {
    busy = false;
    errorText = userMessage;
    errorCode = code;
    debugPrint('RecoverySession failure: $userMessage ($technical)');
    _safeNotify();
  }

  /// Extracts the classified code when the stream error is a typed
  /// EngineException; anything else stays unclassified.
  static FrfErrorCode _codeOf(Object e) =>
      e is EngineException ? e.code : FrfErrorCode.unknown;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
