// test/widgets_test.dart — screen-level widget tests (interaction evidence).
// Each screen renders against a scripted/fake session and key interactions
// are driven end-to-end.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:files_recovery_free/app_brand.dart';
import 'package:files_recovery_free/design/tokens.dart';
import 'package:files_recovery_free/engine/recovery_engine.dart';
import 'package:files_recovery_free/l10n/app_strings.dart';
import 'package:files_recovery_free/main.dart';
import 'package:files_recovery_free/state/recovery_session.dart';
import 'package:files_recovery_free/widgets/core.dart';

class _InstantEngine implements RecoveryEngine {
  @override
  Future<List<DeviceInfo>> listDevices() async => const [
        DeviceInfo(
            id: 'd1',
            name: 'Instant (1 GB)',
            totalBytes: 1024 * 1024 * 1024,
            kind: DeviceKind.sdCard,
            mounted: true,
            fileSystem: 'FAT32'),
        DeviceInfo(
            id: 'sys',
            name: 'System (10 GB)',
            totalBytes: 10 * 1024 * 1024 * 1024,
            kind: DeviceKind.internalDisk,
            mounted: true,
            isSystemDisk: true),
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
      40,
      (i) => RecoveredFile(
          id: 'f$i',
          name: 'DSC_00$i.JPG',
          relativeFolder: 'DCIM',
          sizeBytes: 2 * 1024 * 1024,
          kind: FileKind.photo,
          capturedAt: DateTime(2024, 5, 1 + i % 28),
          state: i % 4 == 0 ? FileState.damaged : FileState.intact,
          duplicate: i % 5 == 0,
          confidencePercent: 92));

  @override
  Stream<EngineProgress> recover(
      String sessionId, List<String> fileIds, Uri destination,
      {required bool keepFolderStructure, required bool byCaptureDate}) {
    _receipts = [
      for (final id in fileIds)
        RecoveryReceipt(
            fileId: id,
            fileName: 'DSC_00${id.substring(1)}.JPG',
            verified: true,
            targetPath:
                '${destination.toFilePath()}DCIM/DSC_00${id.substring(1)}.JPG'),
    ];
    return _stream();
  }

  List<RecoveryReceipt> _receipts = const [];

  @override
  Future<List<RecoveryReceipt>> receipts() async => List.of(_receipts);

  @override
  String get engineName => 'Instant engine';

  @override
  bool get isDemo => true;

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

    @override
  Future<void> cancel() async {}

  Stream<EngineProgress> _stream() async* {
    for (var i = 1; i <= 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      yield EngineProgress(
          doneBytes: i * 50,
          totalBytes: 100,
          filesFound: i * 20,
          phase: i == 2 ? ScanPhase.done : ScanPhase.running);
    }
  }
}

Future<RecoverySession> pumpApp(WidgetTester tester,
    {Size size = const Size(1280, 800)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final s = RecoverySession(engine: _InstantEngine());
  await tester.pumpWidget(FilesRecoveryFreeApp(session: s));
  await tester.pumpAndSettle();
  return s;
}

Future<void> _loadFonts() async {
  final loader = FontLoader('Carlito');
  for (final f in Directory('assets/fonts')
      .listSync()
      .whereType<File>()) {
    final bytes = await f.readAsBytes();
    loader.addFont(Future.value(
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length)));
  }
  await loader.load();
}

void main() {
  setUpAll(() async {
    await _loadFonts();
  });

  testWidgets('shell shows brand bar, step dots and device cards',
      (tester) async {
    final s = await pumpApp(tester);
    expect(find.text(AppBrand.storeDisplayName), findsOneWidget);
    expect(find.text(S.chooseTitle), findsOneWidget);
    expect(find.text('Instant (1 GB)'), findsOneWidget);
    expect(find.byIcon(Icons.lock_rounded), findsOneWidget,
        reason: 'system disk shows the lock affordance');
    expect(s.step, WizardStep.choose);
  });

  testWidgets('end-to-end happy path: choose -> recover done (desktop)',
      (tester) async {
    final s = await pumpApp(tester);

    // Step 1: pick the removable drive and continue.
    await tester.tap(find.text('Instant (1 GB)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.chooseContinue));
    await tester.pumpAndSettle();
    expect(s.step, WizardStep.survey);
    expect(find.byType(DriveMap), findsOneWidget);

    // Step 2 -> 3.
    await tester.tap(find.text(S.surveyCta));
    await tester.pumpAndSettle();
    expect(s.step, WizardStep.backup);

    // Step 3: skip -> scan runs (instant engine) -> lands on Look.
    await tester.tap(find.text(S.backupSkip));
    await tester.pumpAndSettle();
    expect(s.step, WizardStep.look);
    expect(find.byType(FileBadge), findsWidgets);

    // Step 5: select two rows via toggle.
    await tester.tap(find.text('DSC_001.JPG').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('DSC_002.JPG').first);
    await tester.pumpAndSettle();
    expect(s.selectedCount, 2);

    // Step 6: the instant engine completes the run within pumpAndSettle,
    // so the wizard should already show the verified receipt screen.
    await tester.tap(find.text(S.lookContinue));
    await tester.pumpAndSettle();
    expect(s.step, WizardStep.recover);
    expect(s.recoverPhase, RecoverPhase.done,
        reason: 'instant engine finishes before the next settled frame');
    expect(find.text(S.recoverDoneTitle), findsOneWidget);
    expect(find.byIcon(Icons.verified_rounded), findsOneWidget);
  });

  testWidgets('phone layout uses compact dots instead of rail',
      (tester) async {
    await pumpApp(tester, size: const Size(390, 844));
    expect(find.byType(StepDots), findsOneWidget);
    expect(find.text(S.chooseTitle), findsOneWidget);
    // Continue disabled until a device is chosen.
    final cta = tester.widget<FilledButton>(
        find.ancestor(
            of: find.text(S.chooseContinue),
            matching: find.byType(FilledButton)));
    expect(cta.onPressed, isNull);
  });

  testWidgets('license sheet: bad key shows error, good key unlocks',
      (tester) async {
    final s = await pumpApp(tester);
    await tester.tap(find.textContaining('Pro'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'WRONG-KEY');
    await tester.tap(find.text(S.licenseActivate));
    await tester.pumpAndSettle();
    expect(find.text(S.licenseBadKey), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'FRF-ABCD-2345');
    await tester.tap(find.text(S.licenseActivate));
    await tester.pumpAndSettle();
    expect(s.licensed, isTrue);
    expect(find.text('Pro', findRichText: true), findsWidgets);
  });

  testWidgets('flavor mapping covers all platforms', (tester) async {
    expect(flavorFor(TargetPlatform.macOS), PlatformFlavor.cupertino);
    expect(flavorFor(TargetPlatform.iOS), PlatformFlavor.cupertino);
    expect(flavorFor(TargetPlatform.android), PlatformFlavor.material);
    expect(flavorFor(TargetPlatform.windows), PlatformFlavor.fluent);
    expect(flavorFor(TargetPlatform.linux), PlatformFlavor.fluent);
  });

  testWidgets('viewport classes map responsively', (tester) async {
    expect(viewportClassFor(const Size(1280, 800)), ViewportClass.desktop);
    expect(viewportClassFor(const Size(900, 700)), ViewportClass.tablet);
    expect(viewportClassFor(const Size(844, 390)),
        ViewportClass.phoneLandscape);
    expect(viewportClassFor(const Size(390, 844)),
        ViewportClass.phonePortrait);
  });
}
