// test/session_test.dart — state machine unit tests (wizard logic evidence).
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:files_recovery_free/engine/recovery_engine.dart';
import 'package:files_recovery_free/state/recovery_session.dart';

/// Scripted engine: deterministic results, full observability of calls.
class ScriptedEngine implements RecoveryEngine {
  bool cancelled = false;
  List<RecoveryReceipt> _receipts = const [];
  @override
  Future<List<DeviceInfo>> listDevices() async => const [
        DeviceInfo(
            id: 'd1',
            name: 'Scripted (1 GB)',
            totalBytes: 1024 * 1024 * 1024,
            kind: DeviceKind.usbStick,
            mounted: true),
        DeviceInfo(
            id: 'sys',
            name: 'System (10 GB)',
            totalBytes: 10 * 1024 * 1024 * 1024,
            kind: DeviceKind.internalDisk,
            mounted: true,
            isSystemDisk: true),
      ];

  @override
  Future<SurveyResult> survey(DeviceInfo device) async =>
      const SurveyResult(
          dataPercent: 50, unreadablePercent: 1, wipePatternDetected: false);

  @override
  Future<int> freeBytes(Uri dir) async => 8 * 1024 * 1024 * 1024;

  @override
  Stream<EngineProgress> createBackup(DeviceInfo device, Uri destination) =>
      _stream();

  @override
  Stream<EngineProgress> scan(DeviceInfo device, {bool useBackupCopy = true}) =>
      _stream();

  @override
  Future<List<RecoveredFile>> browse(String sessionId) async => List.generate(
      30,
      (i) => RecoveredFile(
          id: 'f$i',
          name: 'file$i.jpg',
          relativeFolder: 'DCIM',
          sizeBytes: 1024 * (i + 1),
          kind: FileKind.photo,
          capturedAt: DateTime(2024),
          state: FileState.intact,
          duplicate: false,
          confidencePercent: 95));

  @override
  Stream<EngineProgress> recover(
      String sessionId, List<String> fileIds, Uri destination,
      {required bool keepFolderStructure, required bool byCaptureDate}) {
    // Engine-sourced receipts (same contract the FFI engine honors).
    _receipts = [
      for (final id in fileIds)
        RecoveryReceipt(
            fileId: id,
            fileName: 'file${id.substring(1)}.jpg',
            verified: true,
            targetPath:
                '${destination.toFilePath()}DCIM/file${id.substring(1)}.jpg'),
    ];
    return _stream();
  }

  @override
  Future<List<RecoveryReceipt>> receipts() async => List.of(_receipts);

  @override
  String get engineName => 'Scripted engine';

  @override
  bool get isDemo => true;

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

    @override
  Future<void> cancel() async => cancelled = true;

  Stream<EngineProgress> _stream() async* {
    for (var i = 1; i <= 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      yield EngineProgress(
          doneBytes: i * 100,
          totalBytes: 300,
          filesFound: i * 10,
          phase: i == 3 ? ScanPhase.done : ScanPhase.running);
    }
  }
}

void main() {
  late RecoverySession s;
  late ScriptedEngine engine;

  setUp(() {
    engine = ScriptedEngine();
    s = RecoverySession(engine: engine);
  });
  tearDown(() => s.dispose());

  test('refreshDevices loads devices; system disk cannot be selected',
      () async {
    await s.refreshDevices();
    expect(s.devices, hasLength(2));
    expect(s.selectDevice('sys'), isFalse,
        reason: 'system disk stays locked with explanation');
    expect(s.selectedDevice, isNull);
    expect(s.selectDevice('d1'), isTrue);
    expect(s.selectedDevice?.id, 'd1');
  });

  test('full happy path: choose -> survey -> backup -> scan -> look',
      () async {
    await s.refreshDevices();
    s.selectDevice('d1');
    await s.runSurvey();
    expect(s.step, WizardStep.survey);
    expect(s.surveyResult, isNotNull);

    s.goBackup();
    expect(s.step, WizardStep.backup);
    s.confirmBackupDone(); // jumps straight into scan
    // wait for the scripted scan (3 quick events) + browse
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(s.step, WizardStep.look);
    expect(s.foundFiles, hasLength(30));
    expect(s.backupDone, isTrue);
  });

  test('skipBackup scans without the copy', () async {
    await s.refreshDevices();
    s.selectDevice('d1');
    await s.runSurvey();
    s.goBackup();
    s.skipBackup();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(s.step, WizardStep.look);
    expect(s.backupDone, isFalse);
  });

  test('selection: toggle, selectAllVisible, clearSelection, bytes math',
      () async {
    await s.refreshDevices();
    s.selectDevice('d1');
    await s.runSurvey();
    s.goBackup();
    s.skipBackup();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    s.toggleSelect('f0');
    expect(s.selectedCount, 1);
    s.toggleSelect('f0');
    expect(s.selectedCount, 0);
    s.selectAllVisible();
    expect(s.selectedCount, 30);
    expect(s.selectedBytes,
        s.foundFiles.fold<int>(0, (a, f) => a + f.sizeBytes));
    s.clearSelection();
    expect(s.selectedCount, 0);
  });

  test('free-tier gate: >25 selected requires upgrade unless licensed',
      () async {
    await s.refreshDevices();
    s.selectDevice('d1');
    await s.runSurvey();
    s.goBackup();
    s.skipBackup();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    s.selectAllVisible();
    expect(s.selectedCount, 30);
    expect(s.needsUpgradeForSelection, isTrue);

    // Bad key rejected.
    expect(s.activateLicense('nope'), isFalse);
    expect(s.licensed, isFalse);

    // Valid key unlocks.
    expect(s.activateLicense('frf-abcd-2345'), isTrue,
        reason: 'keys are case-insensitive');
    expect(s.licensed, isTrue);
    expect(s.needsUpgradeForSelection, isFalse);
  });

  test('recover happy path produces receipts', () async {
    await s.refreshDevices();
    s.selectDevice('d1');
    await s.runSurvey();
    s.goBackup();
    s.skipBackup();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    s.toggleSelect('f0');
    s.toggleSelect('f1');
    s.startRecovery();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(s.recoverPhase, RecoverPhase.done);
    expect(s.receipts, hasLength(2));
    expect(s.receipts.every((r) => r.verified), isTrue);
    expect(s.receipts.first.targetPath, contains('file0.jpg'));
    // Receipts are ENGINE-sourced: they must match the engine's own answer
    // (no fabrication from scan metadata anywhere in the UI layer).
    final engineAnswer = await s.engine.receipts();
    expect(s.receipts.first.targetPath, engineAnswer.first.targetPath);
    expect(s.receipts.length, engineAnswer.length);
  });

  test('startRecovery is a no-op when nothing selected', () async {
    await s.refreshDevices();
    s.selectDevice('d1');
    await s.runSurvey();
    s.goBackup();
    s.skipBackup();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    s.startRecovery();
    expect(s.recoverPhase, RecoverPhase.configure);
    expect(s.step, WizardStep.look);
  });

  test('reset() clears everything including subscriptions', () async {
    await s.refreshDevices();
    s.selectDevice('d1');
    await s.runSurvey();
    s.goBackup();
    s.skipBackup();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    s.selectAllVisible();
    s.reset();
    expect(s.step, WizardStep.choose);
    expect(s.foundFiles, isEmpty);
    expect(s.selectedCount, 0);
    expect(s.surveyResult, isNull);
    expect(s.backupDone, isFalse);
  });

  test('back navigation is guarded', () async {
    expect(s.canGoBack, isFalse);
    s.back();
    expect(s.step, WizardStep.choose); // unchanged
    await s.refreshDevices();
    s.selectDevice('d1');
    await s.runSurvey();
    expect(s.canGoBack, isTrue);
    s.back();
    expect(s.step, WizardStep.choose);
  });
}
