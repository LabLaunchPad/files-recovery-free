// test/golden_test.dart — the golden screenshot matrix (verification layer).
// 4 viewports x 6 wizard steps = 24 goldens, plus license sheet + recovery
// receipt on desktop = 26. Deterministic: scripted engine, real bundled font,
// reduced-motion honored.
//
// Regenerate with: flutter test --update-goldens test/golden_test.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:files_recovery_free/engine/recovery_engine.dart';
import 'package:files_recovery_free/main.dart';
import 'package:files_recovery_free/state/recovery_session.dart';

/// Engine that walks a scripted progress sequence and holds at the end so a
/// mid-flight screen can be captured deterministically.
class HeldScriptEngine implements RecoveryEngine {
  @override
  Future<List<DeviceInfo>> listDevices() async => const [
        DeviceInfo(
            id: 'd1',
            name: 'Golden SD (32 GB)',
            totalBytes: 32 * 1024 * 1024 * 1024,
            kind: DeviceKind.sdCard,
            mounted: true,
            fileSystem: 'FAT32'),
        DeviceInfo(
            id: 'usb1',
            name: 'Cruzer (16 GB)',
            totalBytes: 16 * 1024 * 1024 * 1024,
            kind: DeviceKind.usbStick,
            mounted: false,
            fileSystem: 'exFAT'),
        DeviceInfo(
            id: 'ext1',
            name: 'Backup Plus (2 TB)',
            totalBytes: 2199023255552,
            kind: DeviceKind.externalDisk,
            mounted: true,
            fileSystem: 'NTFS'),
        DeviceInfo(
            id: 'sys0',
            name: 'System Disk (512 GB)',
            totalBytes: 549755813888,
            kind: DeviceKind.internalDisk,
            mounted: true,
            isSystemDisk: true,
            fileSystem: 'APFS'),
      ];

  @override
  Future<SurveyResult> survey(DeviceInfo device) async => const SurveyResult(
      dataPercent: 38, unreadablePercent: 2.1, wipePatternDetected: false);

  @override
  Stream<EngineProgress> createBackup(DeviceInfo device, Uri destination) =>
      _hold(fraction: 0.34, found: 0);

  @override
  Stream<EngineProgress> scan(DeviceInfo device, {bool useBackupCopy = true}) =>
      _hold(fraction: 0.62, found: 217);

  @override
  Future<List<RecoveredFile>> browse(String sessionId) async =>
      _catalogFromJson();

  @override
  Stream<EngineProgress> recover(
      String sessionId, List<String> fileIds, Uri destination,
      {required bool keepFolderStructure, required bool byCaptureDate}) =>
      _hold(fraction: 0.55, found: fileIds.length);

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

    @override
  Future<void> cancel() async {}

  Stream<EngineProgress> _hold(
      {required double fraction, required int found}) async* {
    yield EngineProgress(
        doneBytes: (fraction * 100).round(),
        totalBytes: 100,
        unreadableAreas: 3,
        filesFound: found,
        phase: ScanPhase.running);
    // Hold forever: the harness captures the frame, then the test ends.
    await Completer<void>().future;
  }

  /// Small deterministic catalog loaded from JSON so goldens are stable and
  /// the file is inspectable evidence.
  List<RecoveredFile> _catalogFromJson() {
    final raw = const JsonDecoder().convert(_catalogJson) as List<dynamic>;
    return raw.map((e) {
      final m = e as Map<String, dynamic>;
      return RecoveredFile(
        id: m['id'] as String,
        name: m['name'] as String,
        relativeFolder: m['folder'] as String,
        sizeBytes: m['bytes'] as int,
        kind: FileKind.values.byName(m['kind'] as String),
        capturedAt: DateTime(2024, 3, 14, 9, 30),
        state: FileState.values.byName(m['state'] as String),
        duplicate: m['dup'] as bool,
        confidencePercent: m['conf'] as int,
      );
    }).toList();
  }
}

const String _catalogJson = '''
[
 {"id":"f0","name":"DSC_0421.JPG","folder":"DCIM/100NIKON","bytes":8396800,"kind":"photo","state":"intact","dup":false,"conf":98},
 {"id":"f1","name":"DSC_0422.JPG","folder":"DCIM/100NIKON","bytes":8112140,"kind":"photo","state":"intact","dup":false,"conf":97},
 {"id":"f2","name":"DSC_0423.NEF","folder":"DCIM/100NIKON (orphaned)","bytes":24115200,"kind":"raw","state":"fragmented","dup":false,"conf":64},
 {"id":"f3","name":"MOV_0007.MP4","folder":"PRIVATE/M4ROOT/CLIP","bytes":512000000,"kind":"video","state":"damaged","dup":false,"conf":51},
 {"id":"f4","name":"IMG_0033.PNG","folder":"DCIM/101NIKON","bytes":2214000,"kind":"photo","state":"intact","dup":true,"conf":96},
 {"id":"f5","name":"report_draft.pdf","folder":"Documents","bytes":1456000,"kind":"document","state":"intact","dup":false,"conf":94},
 {"id":"f6","name":"VOICE_012.M4A","folder":"Voice","bytes":33000000,"kind":"audio","state":"intact","dup":false,"conf":91},
 {"id":"f7","name":"backup_01.zip","folder":"Backups","bytes":250000000,"kind":"archive","state":"damaged","dup":false,"conf":48}
]
''';

// ------------------------------------------------------------- harness
const _viewports = <String, Size>{
  'phone_portrait': Size(390, 844),
  'phone_landscape': Size(844, 390),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

Future<void> _loadFonts() async {
  final dir = Directory('assets/fonts');
  final loader = FontLoader('Carlito');
  for (final f in dir.listSync().whereType<File>()) {
    final bytes = await f.readAsBytes();
    loader.addFont(Future.value(
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length)));
  }
  await loader.load();
}

/// Wraps the app in reduced-motion media so animations are static.
Widget _wrap(Widget child, Size size) {
  return MediaQuery(
    data: MediaQueryData(size: size, disableAnimations: true),
    child: child,
  );
}

Future<void> _pumpViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<RecoverySession> _pumpChoose(WidgetTester tester, Size size) async {
  await _pumpViewport(tester, size);
  final s = RecoverySession(engine: HeldScriptEngine());
  await tester.pumpWidget(_wrap(FilesRecoveryFreeApp(session: s), size));
  await tester.runAsync(() => s.refreshDevices());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return s;
}

Future<RecoverySession> _pumpStep(
    WidgetTester tester, Size size, WizardStep target) async {
  final s = await _pumpChoose(tester, size);
  s.selectDevice('d1');

  if (target == WizardStep.choose) return s;

  // Survey.
  await tester.runAsync(() => s.runSurvey());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  if (target == WizardStep.survey) return s;

  // Backup.
  s.goBackup();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  if (target == WizardStep.backup) return s;

  // Scan: the engine holds mid-progress for a stable capture.
  s.startScan(useBackupCopy: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  if (target == WizardStep.scan) return s;

  // Look: build the results state directly (no held stream involved).
  s.foundFiles = await tester.runAsync(() => s.engine.browse('session')) ?? [];
  s.selectAllVisible();
  s.toggleSelect('f2'); // unselect one -> mixed selection state
  s.openLook();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  if (target == WizardStep.look) return s;

  // Recover (configure): selection of 7 files is under the free cap.
  s.startRecovery();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return s;
}

void main() {
  setUpAll(() async {
    await _loadFonts();
  });

  for (final entry in _viewports.entries) {
    final vpName = entry.key;
    final size = entry.value;

    testWidgets('golden: $vpName/01_choose', (tester) async {
      await _pumpChoose(tester, size);
      await expectLater(find.byType(FilesRecoveryFreeApp),
          matchesGoldenFile('goldens/$vpName/01_choose.png'));
    });

    testWidgets('golden: $vpName/02_survey', (tester) async {
      await _pumpStep(tester, size, WizardStep.survey);
      await expectLater(find.byType(FilesRecoveryFreeApp),
          matchesGoldenFile('goldens/$vpName/02_survey.png'));
    });

    testWidgets('golden: $vpName/03_backup', (tester) async {
      await _pumpStep(tester, size, WizardStep.backup);
      await expectLater(find.byType(FilesRecoveryFreeApp),
          matchesGoldenFile('goldens/$vpName/03_backup.png'));
    });

    testWidgets('golden: $vpName/04_scan', (tester) async {
      await _pumpStep(tester, size, WizardStep.scan);
      await expectLater(find.byType(FilesRecoveryFreeApp),
          matchesGoldenFile('goldens/$vpName/04_scan.png'));
    });

    testWidgets('golden: $vpName/05_look', (tester) async {
      await _pumpStep(tester, size, WizardStep.look);
      await expectLater(find.byType(FilesRecoveryFreeApp),
          matchesGoldenFile('goldens/$vpName/05_look.png'));
    });

    testWidgets('golden: $vpName/06_recover', (tester) async {
      await _pumpStep(tester, size, WizardStep.recover);
      await expectLater(find.byType(FilesRecoveryFreeApp),
          matchesGoldenFile('goldens/$vpName/06_recover.png'));
    });
  }

  testWidgets('golden: desktop/07_license_sheet', (tester) async {
    await _pumpChoose(tester, _viewports['desktop']!);
    await tester.tap(find.textContaining('Pro'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(FilesRecoveryFreeApp),
        matchesGoldenFile('goldens/desktop/07_license_sheet.png'));
  });

  testWidgets('golden: desktop/08_recover_done', (tester) async {
    final size = _viewports['desktop']!;
    final s = await _pumpChoose(tester, size);
    await tester.runAsync(() async {
      s.selectDevice('d1');
      await s.runSurvey();
      s.goBackup();
      s.foundFiles = await s.engine.browse('session');
      s.selectedFileIds.addAll(['f0', 'f1', 'f5']);
      s.startRecovery();
      // Force the completed state for the receipt capture.
      s.recoverPhase = RecoverPhase.done;
      s.busy = false;
      s.receipts.clear();
      for (final id in s.selectedFileIds) {
        s.receipts.add(RecoveryReceipt(
            fileId: id,
            fileName: 'file_$id.jpg',
            verified: true,
            targetPath:
                '/tmp/files-recovery-free/output/DCIM/100NIKON/file_$id.jpg'));
      }
      s.notifyListeners();
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await expectLater(find.byType(FilesRecoveryFreeApp),
        matchesGoldenFile('goldens/desktop/08_recover_done.png'));
  });
}
