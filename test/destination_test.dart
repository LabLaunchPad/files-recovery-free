// test/destination_test.dart — destination picker flow + safety rules.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:files_recovery_free/engine/recovery_engine.dart';
import 'package:files_recovery_free/engine/simulated_engine.dart';
import 'package:files_recovery_free/state/destination.dart';
import 'package:files_recovery_free/state/recovery_session.dart';

void main() {
  group('DestinationSafety.isInsideOrEqual', () {
    test('rejects empty roots defensively', () {
      expect(DestinationSafety.isInsideOrEqual('/tmp/x', ''), isFalse);
      expect(DestinationSafety.isInsideOrEqual('', '/tmp'), isFalse);
    });

    test('mount-point containment (unix)', () {
      expect(
        DestinationSafety.isInsideOrEqual(
            '/media/usb/stuff/out', '/media/usb'),
        isTrue,
      );
      expect(
        DestinationSafety.isInsideOrEqual('/media/usb', '/media/usb'),
        isTrue,
      );
      // prefix must respect the separator boundary: /media/usb2 is a
      // DIFFERENT drive than /media/usb
      expect(
        DestinationSafety.isInsideOrEqual('/media/usb2/out', '/media/usb'),
        isFalse,
      );
    });

    test('unrelated paths never match', () {
      expect(
        DestinationSafety.isInsideOrEqual('/tmp/out', '/media/usb'),
        isFalse,
      );
    }, skip: Platform.isWindows ? 'unix paths' : null);

    test('windows roots compare case-insensitively', () {
      expect(
        DestinationSafety.isInsideOrEqual(r'd:\recovered', r'D:\'),
        isTrue,
      );
    }, skip: Platform.isWindows ? null : 'windows-only');
  });

  group('DestinationSafety.evaluate', () {
    const usb = DeviceInfo(
      id: 'usb1',
      name: 'USB stick',
      totalBytes: 16 * 1024 * 1024 * 1024,
      kind: DeviceKind.usbStick,
      mounted: true,
      sourcePath: '/dev/sdb1',
      mountPoint: '/media/user/USB',
    );

    test('blocks destinations on the source drive', () {
      final c = DestinationSafety.evaluate(
        dir: '/media/user/USB/rescued',
        source: usb,
        neededBytes: 100,
        freeBytes: 1000,
        probeRan: true,
        writable: true,
      );
      expect(c.ok, isFalse);
      expect(c.onSourceDrive, isTrue);
      expect(c.blockers, isNotEmpty);
    });

    test('blocks unwritable destinations', () {
      final c = DestinationSafety.evaluate(
        dir: '/tmp/readonly',
        source: usb,
        neededBytes: 100,
        freeBytes: 1000,
        probeRan: true,
        writable: false,
      );
      expect(c.ok, isFalse);
      expect(c.blockers.first, contains('not writable'));
    });

    test('blocks when space is insufficient, warns when tight', () {
      final full = DestinationSafety.evaluate(
        dir: '/tmp/out',
        source: usb,
        neededBytes: 1000,
        freeBytes: 900,
        probeRan: true,
        writable: true,
      );
      expect(full.ok, isFalse);

      final tight = DestinationSafety.evaluate(
        dir: '/tmp/out',
        source: usb,
        neededBytes: 1000,
        freeBytes: 1050, // < needed * 1.10 headroom
        probeRan: true,
        writable: true,
      );
      expect(tight.ok, isTrue);
      expect(tight.warnings, isNotEmpty);
    });

    test('unknown space (0) warns instead of blocking', () {
      final c = DestinationSafety.evaluate(
        dir: '/tmp/out',
        source: null,
        neededBytes: 1000,
        freeBytes: 0,
        probeRan: true,
        writable: true,
      );
      expect(c.ok, isTrue);
      expect(c.blockers, isEmpty);
    });

    test('writability probe creates and cleans up', () async {
      final dir = Directory.systemTemp.createTempSync('frf_probe');
      try {
        final (ran, ok) = await DestinationSafety.probeWritable(dir.path);
        expect(ran, kIsWeb ? isFalse : isTrue);
        if (!kIsWeb) expect(ok, isTrue);
        expect(FileSystemEntity.typeSync('${dir.path}/.frf_write_probe'),
            FileSystemEntityType.notFound);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('per-OS default roots keep the classic /tmp path on unix', () {
      if (Platform.isWindows) {
        expect(defaultDestinationRoot(), contains(r'\files-recovery-free\'));
      } else {
        expect(defaultDestinationRoot(),
            '${Directory.systemTemp.path}/files-recovery-free/output');
      }
    });
  });

  group('RecoverySession destination flow', () {
    test('pick → evaluate → start writes to the chosen folder', () async {
      final s = RecoverySession(engine: SimulatedEngine(tickScale: 100));
      await s.refreshDevices();
      expect(s.selectDevice('card1'), isTrue);

      final picked = Directory.systemTemp.createTempSync('frf_pick');
      addTearDown(() => picked.deleteSync(recursive: true));
      var pickerCalls = 0;
      s.pickDirectory = () async {
        pickerCalls++;
        return picked.path;
      };

      await s.chooseDestination();
      expect(pickerCalls, 1);
      expect(s.destinationChosen, isTrue);
      expect(s.destinationPath, picked.path);
      expect(s.destinationCheck, isNotNull);
      expect(s.destinationCheck!.ok, isTrue);

      // user cancel keeps the previous choice
      s.pickDirectory = () async => null;
      await s.chooseDestination();
      expect(s.destinationPath, picked.path);

      // full e2e: scan then recover into the picked folder
      await s.runSurvey();
      s.confirmBackupDone(); // scan via backup-copy=true path
      // wait for scan completion (instant in simulated engine's ticks)
      for (var i = 0; i < 400 && s.step != WizardStep.look; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(s.step, WizardStep.look);
      for (final f in s.foundFiles.take(3)) {
        s.toggleSelect(f.id); // 3 files stay under the free-tier gate
      }
      await s.startRecovery();
      for (var i = 0; i < 400 && s.recoverPhase != RecoverPhase.done; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(s.recoverPhase, RecoverPhase.done);
      // receipts carry the chosen destination (engine-sourced evidence)
      expect(s.receipts, isNotEmpty);
      expect(s.receipts.first.targetPath, startsWith(picked.path));

      // reset clears the destination with the rest of the session
      s.reset();
      expect(s.destinationChosen, isFalse);
      expect(s.destinationPath, isNull);
    });

    test('blocked destination refuses to start and reports a typed error',
        () async {
      final s = RecoverySession(engine: SimulatedEngine(tickScale: 100));
      await s.refreshDevices();
      expect(s.selectDevice('ext1'), isTrue); // mountPoint /media/user/BackupPlus
      s.destinationPath = '/media/user/BackupPlus/rescued';
      s.destinationChosen = true;

      await s.runSurvey();
      s.skipBackup();
      for (var i = 0; i < 400 && s.step != WizardStep.look; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      for (final f in s.foundFiles.take(3)) {
        s.toggleSelect(f.id);
      }
      await s.startRecovery();
      expect(s.recoverPhase, RecoverPhase.configure); // bounced back
      expect(s.errorText, contains('source'));
      expect(s.errorCode, FrfErrorCode.destinationInvalid);
      expect(s.busy, isFalse);
    });
  });
}
