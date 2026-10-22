// test/accessibility_test.dart — Phase 4 Semantics pass (REA ledger item).
//
// Asserts the semantics TREE, not pixels: buttons expose labels, the
// decorative animation is invisible to screen readers, progress is
// announced as a percentage, and the step rail says where you are.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:files_recovery_free/engine/recovery_engine.dart';
import 'package:files_recovery_free/l10n/app_strings.dart';
import 'package:files_recovery_free/main.dart';
import 'package:files_recovery_free/state/recovery_session.dart';
import 'package:files_recovery_free/widgets/core.dart';

class _A11yEngine implements RecoveryEngine {
  @override
  Future<int> freeBytes(Uri dir) async => 8 * 1024 * 1024 * 1024;

  @override
  Future<List<DeviceInfo>> listDevices() async => const [
        DeviceInfo(
            id: 'd1',
            name: 'A11y Card (2 GB)',
            totalBytes: 2 * 1024 * 1024 * 1024,
            kind: DeviceKind.sdCard,
            mounted: true,
            fileSystem: 'exFAT'),
      ];

  @override
  Future<SurveyResult> survey(DeviceInfo device) async => const SurveyResult(
      dataPercent: 42, unreadablePercent: 1.5, wipePatternDetected: false);

  @override
  Stream<EngineProgress> createBackup(DeviceInfo device, Uri destination) =>
      _stream();

  @override
  Stream<EngineProgress> scan(DeviceInfo device, {bool useBackupCopy = true}) =>
      _stream();

  @override
  Future<List<RecoveredFile>> browse(String sessionId) async => List.generate(
      3,
      (i) => RecoveredFile(
          id: 'f$i',
          name: 'DSC_00$i.JPG',
          relativeFolder: 'DCIM',
          sizeBytes: 2 * 1024 * 1024,
          kind: FileKind.photo,
          capturedAt: DateTime(2024, 5, 1 + i),
          state: FileState.intact,
          duplicate: false,
          confidencePercent: 92));

  @override
  Stream<EngineProgress> recover(
      String sessionId, List<String> fileIds, Uri destination,
      {required bool keepFolderStructure, required bool byCaptureDate}) =>
      _stream();

  @override
  Future<List<RecoveryReceipt>> receipts() async => const [];

  @override
  Future<DeviceInfo> addImageSource(String path) async => throw UnimplementedError();

  @override
  Future<LicenseVerification> verifyLicense(String key) async =>
      const LicenseVerification(valid: false, signed: false);

  @override
  Future<void> cancel() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  String get engineName => 'A11y engine';

  @override
  bool get isDemo => true;

  Stream<EngineProgress> _stream() async* {
    for (var i = 1; i <= 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      yield EngineProgress(
          doneBytes: i * 50,
          totalBytes: 100,
          filesFound: 3,
          phase: i == 2 ? ScanPhase.done : ScanPhase.running);
    }
  }
}

Future<RecoverySession> _pump(WidgetTester tester,
    {Size size = const Size(1280, 800)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final s = RecoverySession(engine: _A11yEngine())
    ..destinationProbeEnabled = false;
  await tester.pumpWidget(FilesRecoveryFreeApp(session: s));
  await tester.pumpAndSettle();
  return s;
}

Future<void> _loadFonts() async {
  final loader = FontLoader('Carlito');
  for (final f in Directory('assets/fonts').listSync().whereType<File>()) {
    final bytes = await f.readAsBytes();
    loader.addFont(Future.value(
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length)));
  }
  await loader.load();
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('device cards expose button semantics with a spoken name',
      (tester) async {
    await _pump(tester);
    final handle = tester.ensureSemantics();
    expect(
        find.bySemanticsLabel(RegExp('.*A11y Card.*exFAT.*')), findsOneWidget);
    // The card acts as a button (Semantics(button: true) on _DeviceCard).
    final card = find.bySemanticsLabel(RegExp('.*A11y Card.*')).first;
    final node = tester.getSemantics(card);
    expect(node.flagsCollection.isButton, isTrue);
    handle.dispose();
  });

  testWidgets('the step rail announces the current step (phone layout)',
      (tester) async {
    await _pump(tester, size: const Size(390, 760));
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('Step 1 of 6: Choose')),
        findsOneWidget);
    handle.dispose();
  });

  testWidgets('the demo engine badge identifies itself to screen readers',
      (tester) async {
    await _pump(tester);
    final handle = tester.ensureSemantics();
    expect(
        find.bySemanticsLabel(
            RegExp('.*A11y engine.*demo engine.*')),
        findsOneWidget);
    handle.dispose();
  });

  testWidgets('progress bars announce a percentage', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BlockBar(0.4))));
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Progress: 40%'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the drive map heatmap speaks its data summary', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: DriveMap(
                survey: SurveyResult(
                    dataPercent: 42,
                    unreadablePercent: 1.5,
                    wipePatternDetected: false)))));
    final handle = tester.ensureSemantics();
    expect(
        find.bySemanticsLabel(
            RegExp('.*42% ${S.surveyDataHeld}.*${S.surveyUnreadable}.*')),
        findsOneWidget);
    handle.dispose();
  });

  testWidgets('the decorative dot wave is excluded from semantics',
      (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: Scaffold(body: DotWave())));
    await tester.pump(const Duration(milliseconds: 120));
    // ExcludeSemantics wraps the animation (decorative, no announcement).
    expect(find.byType(ExcludeSemantics), findsWidgets);
  });
}
