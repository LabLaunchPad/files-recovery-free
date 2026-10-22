// test/ffi_engine_test.dart — Phase 2 engine tests: run the REAL Rust
// carving core through dart:ffi, end to end, on a synthetic disk image.
// Skips gracefully when the dynamic library has not been built yet
// (`cargo build --release -p recovery-ffi` or CI provides it).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:files_recovery_free/engine/ffi_engine.dart';
import 'package:files_recovery_free/engine/recovery_engine.dart';

bool _dylibAvailable() {
  final env = Platform.environment['FRF_DYLIB_PATH'];
  if (env != null && env.isNotEmpty) return File(env).existsSync();
  return File('rust/target/release/librecovery_core_ffi.so').existsSync();
}

Uint8List _junk(int len) {
  final alpha = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEF'.codeUnits;
  final out = Uint8List(len);
  for (var i = 0; i < len; i++) {
    out[i] = alpha[i * 7 % alpha.length];
  }
  return out;
}

/// junk + 3 JPEGs (48 KiB each) separated by junk — no signature collisions.
Future<Uri> _buildImage(String path) async {
  final img = BytesBuilder();
  img.add(_junk(256 * 1024));
  for (var i = 0; i < 3; i++) {
    img.add([0xFF, 0xD8, 0xFF, 0xE0]);
    img.add(_junk(48 * 1024));
    img.add([0xFF, 0xD9]);
    img.add(_junk(64 * 1024));
  }
  final f = File(path);
  await f.writeAsBytes(img.takeBytes(), flush: true);
  return Uri.file(path);
}

void main() {
  if (!_dylibAvailable()) {
    test('FFI engine tests skipped (dynamic library not built)', () {
      // `cargo build --release -p recovery-ffi` builds it; CI does this
      // before running the Dart suite.
    });
    return;
  }

  late FfiRecoveryEngine engine;

  setUpAll(() {
    engine = FfiRecoveryEngine.tryLoad()!;
    expect(engine.version, contains('recovery-ffi'));
  });

  test('engine identity: native engine is not demo (watermark gate)', () {
    expect(engine.isDemo, isFalse);
    expect(engine.engineName, contains('Native'));
    expect(engine.engineName, contains(engine.version));
  });

  test('lists the registered disk image as a scannable device', () async {
    final img = await _buildImage(
        '${Directory.systemTemp.path}/frf_dart_img_${DateTime.now().microsecondsSinceEpoch}.img');
    final idx = engine.registerImage(img.toFilePath());
    expect(idx, greaterThanOrEqualTo(0));

    final devices = await engine.listDevices();
    final mine = devices.where((d) => d.id == 'img$idx').toList();
    expect(mine, hasLength(1));
    expect(mine.first.kind, DeviceKind.diskImage);
    expect(mine.first.totalBytes, greaterThan(300 * 1024));
    expect(mine.first.isSystemDisk, isFalse);
  });

  test('full pipeline: survey, scan, browse, recover — byte identical', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final imgPath =
        '${Directory.systemTemp.path}/frf_dart_pipe_$stamp.img';
    await _buildImage(imgPath);
    final idx = engine.registerImage(imgPath);
    final devices = await engine.listDevices();
    final device = devices.firstWhere((d) => d.id == 'img$idx');

    // survey: the image is nearly all data
    final survey = await engine.survey(device);
    expect(survey.dataPercent, greaterThan(90));
    expect(survey.unreadablePercent, 0);
    expect(survey.wipePatternDetected, isFalse);

    // backup: real bit-for-bit copy of the image
    final backupUri = Uri.file('$imgPath.bak');
    final backupDone = await engine.createBackup(device, backupUri).last;
    expect(backupDone.phase, ScanPhase.done);
    expect(File('$imgPath.bak').lengthSync(), File(imgPath).lengthSync());

    // scan against the ORIGINAL (skip the backup copy)
    final phases = <ScanPhase>[];
    int? foundAtEnd;
    await for (final p in engine.scan(device, useBackupCopy: false)) {
      phases.add(p.phase);
      if (p.phase == ScanPhase.done) foundAtEnd = p.filesFound;
    }
    expect(phases.last, ScanPhase.done);
    expect(foundAtEnd, 3, reason: 'three jpegs carved');

    // browse: exact sizes, intact states
    final files = await engine.browse('session');
    expect(files, hasLength(3));
    for (final f in files) {
      expect(f.name, endsWith('.jpg'));
      expect(f.kind, FileKind.photo);
      expect(f.state, FileState.intact);
      expect(f.sizeBytes, 48 * 1024 + 6);
      expect(f.confidencePercent, inInclusiveRange(80, 100));
    }
    expect(files[1].duplicate, isTrue, reason: 'identical copies flagged');

    // recover the first two → verify byte-identical outputs + receipts path
    final outDir = Directory.systemTemp.path;
    final dest = Uri.file('$outDir/frf_dart_out_$stamp');
    final progress = <double>[];
    await for (final p
        in engine.recover('session', [files[0].id, files[1].id], dest,
            keepFolderStructure: true, byCaptureDate: false)) {
      progress.add(p.fraction);
    }
    expect(progress, isNotEmpty);
    expect(progress.last, 1.0, reason: 'recovery reaches completion');

    String joinOut(String folder, String name) {
      final base = dest.toFilePath();
      final sep = base.endsWith('/') ? '' : '/';
      return '$base$sep$folder/$name';
    }

    final written = <List<int>>[];
    for (final f in files.take(2)) {
      final out = File(joinOut(f.relativeFolder, f.name));
      expect(out.existsSync(), isTrue, reason: '${out.path} missing');
      final bytes = await out.readAsBytes();
      expect(bytes.length, f.sizeBytes, reason: 'exact carved length');
      expect(bytes.sublist(0, 3), [0xFF, 0xD8, 0xFF], reason: 'jpeg signature');
      written.add(bytes);
    }
    // the two selected copies are byte-identical (duplicate detection said so)
    expect(written[0], written[1], reason: 'identical content, identical bytes');

    // receipts come from the ENGINE (frf_receipt_*): per-file verification
    // evidence whose target paths point at the files ACTUALLY written above.
    final receipts = await engine.receipts();
    expect(receipts, hasLength(2), reason: 'one receipt per recovered file');
    for (var i = 0; i < 2; i++) {
      expect(receipts[i].fileId, files[i].id);
      expect(receipts[i].fileName, files[i].name);
      expect(receipts[i].verified, isTrue,
          reason: 'recover+verify re-read the bytes from the destination');
      expect(File(receipts[i].targetPath).existsSync(), isTrue,
          reason: 'receipt path must exist: ${receipts[i].targetPath}');
      expect(receipts[i].targetPath,
          startsWith(dest.toFilePath().endsWith('/')
              ? dest.toFilePath()
              : '${dest.toFilePath()}/'));
    }

    // cleanup
    Directory(dest.toFilePath()).deleteSync(recursive: true);
    File('$imgPath.bak').deleteSync();
  });

  test('cancel() ends the scan stream with ScanPhase.cancelled', () async {
    final imgPath =
        '${Directory.systemTemp.path}/frf_dart_cancel_${DateTime.now().microsecondsSinceEpoch}.img';
    // 48 MB so the scan spans many windows and cannot finish before the
    // cooperative cancel lands.
    final big = BytesBuilder();
    big.add(_junk(48 * 1024 * 1024));
    await File(imgPath).writeAsBytes(big.takeBytes(), flush: true);
    final idx = engine.registerImage(imgPath);
    final devices = await engine.listDevices();
    final device = devices.firstWhere((d) => d.id == 'img$idx');

    ScanPhase? terminal;
    await for (final p in engine.scan(device, useBackupCopy: false)) {
      if (p.phase == ScanPhase.running) {
        await engine.cancel();
      }
      terminal = p.phase;
    }
    expect(terminal, ScanPhase.cancelled);
  });

  test('frf_free_bytes reports real free space on a temp volume', () async {
    final tmp = await Directory.systemTemp.createTemp('frf_free');
    try {
      final free = await engine.freeBytes(Uri.file(tmp.path));
      expect(free, greaterThan(0), reason: 'statvfs should report free bytes');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('device enumeration exposes real devices with OS paths', () async {
    final devices = await engine.listDevices();
    for (final d in devices) {
      expect(d.totalBytes, greaterThan(0));
      // every real source carries its OS path so destination safety can
      // compare against the source drive
      expect(d.sourcePath, isNotNull, reason: 'device ${d.id} needs a path');
      expect(d.sourcePath, isNotEmpty);
    }
    // The engine singleton sources include at least the registered image
    // (from earlier tests in this file, order-dependent by design) and any
    // real block devices present on the host. No assertion on count: the
    // ABI test in Rust covers the hard guarantees.
  });
}
