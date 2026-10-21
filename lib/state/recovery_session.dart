// state/recovery_session.dart — wizard state machine (Blueprint Ch. 5).
// Pure Dart: unit-testable without rendering. All engine calls are guarded;
// failures land in [errorText] instead of crashing the wizard, and every
// stream subscription is cancelled on reset/dispose (no leaks).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_brand.dart';
import '../engine/recovery_engine.dart';
import '../engine/simulated_engine.dart';

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
  RecoverPhase recoverPhase = RecoverPhase.configure;
  final List<RecoveryReceipt> receipts = [];
  String? errorText;

  StreamSubscription<EngineProgress>? _sub;
  bool _disposed = false;

  RecoverySession({RecoveryEngine? engine})
      : engine = engine ?? SimulatedEngine();

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
    busy = true;
    notifyListeners();
    try {
      devices = await engine.listDevices();
    } on EngineException catch (e) {
      errorText = e.userMessage;
    } catch (e) {
      errorText = 'Could not list drives. Try again.';
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

  // -------------------------------------------------------------- survey
  Future<void> runSurvey() async {
    if (selectedDevice == null || busy) return;
    _step = WizardStep.survey;
    busy = true;
    errorText = null;
    notifyListeners();
    try {
      surveyResult = await engine.survey(selectedDevice!);
    } on EngineException catch (e) {
      errorText = e.userMessage;
    } catch (_) {
      errorText = 'Could not survey this drive. Try again.';
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
    foundFiles = [];
    notifyListeners();
    _sub?.cancel();
    _sub = engine
        .scan(selectedDevice!, useBackupCopy: useBackupCopy)
        .listen(_onScanEvent,
            onError: (Object e) => _fail('The scan hit a problem and stopped.',
                    'scan-error: $e'));
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
            'next time.');
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
    } catch (e) {
      _fail('Found files could not be listed. Try scanning again.',
          'browse: $e');
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
  /// Simulated license activation. Real builds swap this for a signed-key
  /// verifier (the same CryptoKit/Ed25519 pattern the benchmark app uses).
  bool activateLicense(String key) {
    final normalized = key.trim().toUpperCase();
    final ok = RegExp(r'^FRF(-[A-Z2-7]{4}){2}$').hasMatch(normalized);
    if (ok) {
      licensed = true;
      notifyListeners();
    }
    return ok;
  }

  // ------------------------------------------------------------- recover
  void startRecovery() {
    if (selectedFileIds.isEmpty || needsUpgradeForSelection) return;
    recoverPhase = RecoverPhase.running;
    _step = WizardStep.recover;
    progressFraction = 0;
    busy = true;
    errorText = null;
    receipts.clear();
    notifyListeners();
    _sub?.cancel();
    _sub = engine
        .recover('session', selectedFileIds.toList(),
            Uri.file('/tmp/files-recovery-free/output'),
            keepFolderStructure: true, byCaptureDate: false)
        .listen(_onRecoverEvent,
            onError: (Object e) => _fail(
                'Recovery stopped before finishing. Your files were not '
                'changed.',
                'recover-error: $e'));
  }

  void _onRecoverEvent(EngineProgress p) {
    progressFraction = p.fraction;
    switch (p.phase) {
      case ScanPhase.done:
        busy = false;
        recoverPhase = RecoverPhase.done;
        for (final id in selectedFileIds) {
          final f = foundFiles.firstWhere((x) => x.id == id,
              orElse: () => const RecoveredFile(
                  id: '?',
                  name: '?',
                  relativeFolder: '',
                  sizeBytes: 0,
                  kind: FileKind.other,
                  capturedAt: null,
                  state: FileState.intact,
                  duplicate: false,
                  confidencePercent: 0));
          receipts.add(RecoveryReceipt(
              fileId: id,
              fileName: f.name,
              verified: f.state != FileState.unreadable,
              targetPath:
                  '/tmp/files-recovery-free/output/${f.relativeFolder}/${f.name}'));
        }
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
    busy = false;
    recoverPhase = RecoverPhase.configure;
    receipts.clear();
    filter.clear();
    notifyListeners();
  }

  // -------------------------------------------------------------- internal
  void _fail(String userMessage, [String? technical]) {
    busy = false;
    errorText = userMessage;
    debugPrint('RecoverySession failure: $userMessage ($technical)');
    _safeNotify();
  }

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
