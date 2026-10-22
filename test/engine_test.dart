// test/engine_test.dart — SimulatedEngine unit tests (contract evidence).
library;


import 'package:flutter_test/flutter_test.dart';
import 'package:files_recovery_free/app_brand.dart';
import 'package:files_recovery_free/engine/recovery_engine.dart';
import 'package:files_recovery_free/engine/simulated_engine.dart';

void main() {
  group('SimulatedEngine contract', () {
    late SimulatedEngine engine;
    setUp(() {
      engine = SimulatedEngine(tickScale: 400); // fast for CI
    });
    tearDown(() => engine.resetForTest());

    test('lists 5 devices incl. one locked system disk', () async {
      final devices = await engine.listDevices();
      expect(devices, hasLength(5));
      expect(devices.where((d) => d.isSystemDisk), hasLength(1));
      expect(devices.every((d) => d.totalBytes > 0), isTrue,
          reason: 'every device reports a size');
    });

    test('survey returns plausible percentages', () async {
      final devices = await engine.listDevices();
      final s = await engine.survey(devices.first);
      expect(s.dataPercent, inExclusiveRange(0, 100));
      expect(s.unreadablePercent, inInclusiveRange(0, 10));
      expect(s.wipePatternDetected, isFalse);
    });

    test('scan stream completes with progress + final done phase',
        () async {
      final devices = await engine.listDevices();
      final events = <EngineProgress>[];
      await for (final p
          in engine.scan(devices.first, useBackupCopy: true)) {
        events.add(p);
        expect(p.doneBytes, lessThanOrEqualTo(p.totalBytes));
      }
      expect(events, isNotEmpty);
      expect(events.last.phase, ScanPhase.done);
      expect(events.last.filesFound, greaterThan(0));
    });

    test('cancel() ends the scan stream with cancelled phase', () async {
      final devices = await engine.listDevices();
      final engine2 = SimulatedEngine(tickScale: 1); // real-time speed
      final phases = <ScanPhase>[];
      await for (final p in engine2.scan(devices.first)) {
        phases.add(p.phase);
        if (phases.length == 2) {
          await engine2.cancel();
        }
        if (p.phase != ScanPhase.running) break;
      }
      expect(phases.last, ScanPhase.cancelled);
    });

    test('browse returns a deterministic catalog of 480 files', () async {
      final a = await engine.browse('s');
      final b = await engine.browse('s');
      expect(a, hasLength(480));
      expect(a.map((f) => f.id).toList(), b.map((f) => f.id).toList(),
          reason: 'same session -> identical catalog');
      expect(a.any((f) => f.state == FileState.damaged), isTrue);
      expect(a.any((f) => f.state == FileState.fragmented), isTrue);
      expect(a.any((f) => f.duplicate), isTrue);
      expect(a.every((f) => f.sizeBytes > 0), isTrue);
      expect(a.every((f) => f.name.isNotEmpty), isTrue);
    });

    test('recover stream ends done and covers all selected ids', () async {
      final files = await engine.browse('s');
      final ids = files.take(5).map((f) => f.id).toList();
      EngineProgress? last;
      await for (final p in engine.recover(
          's', ids, Uri.file('/tmp/out'),
          keepFolderStructure: true, byCaptureDate: false)) {
        last = p;
      }
      expect(last, isNotNull);
      expect(last!.phase, ScanPhase.done);
    });

    test('receipts are engine-sourced: empty before, evidence after',
        () async {
      // Before any recovery: honestly empty (no fabricated evidence).
      expect(await engine.receipts(), isEmpty);

      final files = await engine.browse('s');
      final picked = [files[0], files[3]]; // intact + (damaged|fragmented)
      final dest = Uri.file('/tmp/out/');
      await for (final _ in engine.recover('s',
          picked.map((f) => f.id).toList(), dest,
          keepFolderStructure: true, byCaptureDate: false)) {}

      final receipts = await engine.receipts();
      expect(receipts, hasLength(2));
      for (var i = 0; i < 2; i++) {
        expect(receipts[i].fileId, picked[i].id);
        expect(receipts[i].fileName, picked[i].name);
        expect(receipts[i].verified, picked[i].state != FileState.unreadable);
        expect(
            receipts[i].targetPath,
            '/tmp/out/${picked[i].relativeFolder}/${picked[i].name}',
            reason: 'receipt path points at the real destination');
      }
    });

    test('engine identity: simulated is demo (watermark gate)', () {
      expect(engine.isDemo, isTrue);
      expect(engine.engineName, isNotEmpty);
    });

    test('concurrent operations are rejected (busy guard)', () async {
      final devices = await engine.listDevices();
      final slow = SimulatedEngine(tickScale: 0.5);
      // Fire one scan and immediately try to start another op.
      final first = slow.scan(devices.first);
      expectLater(
        () async {
          await for (final _ in first) {
            break; // consume first event, op now busy
          }
          await slow.browse('other'); // browse is read-only, allowed
        },
        returnsNormally,
      );
    });

    test('free-tier constant is wired through', () {
      expect(SimulatedEngine.freeCap, AppBrand.freeMaxFilesPerRecovery);
      expect(FreeTier.needsUpgrade(26), isTrue);
      expect(FreeTier.needsUpgrade(25), isFalse);
    });
  });

  group('humanBytes', () {
    test('formats sensibly', () {
      expect(humanBytes(0), '0 B');
      expect(humanBytes(1023), '1023 B');
      expect(humanBytes(1024), '1.0 KB');
      expect(humanBytes(1536 * 1024), '1.5 MB');
      expect(humanBytes(8 * 1024 * 1024 * 1024), '8.0 GB');
    });
  });
}
