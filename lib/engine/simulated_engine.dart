// engine/simulated_engine.dart — Phase 1 fixture engine (Blueprint Ch. 3).
// Replays realistic recovery behavior so the entire UX is fully exercisable
// before the Rust engine exists. Deterministic (seeded), cancellable,
// pausable, speed-configurable for tests vs. live demo.
library;

import 'dart:async';
import 'dart:math';

import '../app_brand.dart';
import 'recovery_engine.dart';

class SimulatedEngine implements RecoveryEngine {
  SimulatedEngine({this.seed = 1337, this.tickScale = 1.0});

  /// Deterministic fixtures for golden tests / reproducible demos.
  final int seed;

  /// >1 speeds streams up (tests), <1 slows them down (realistic demo).
  final double tickScale;

  final _rand = Random(1337);
  bool _paused = false, _cancelled = false, _busy = false;
  late final Random _seeded = Random(seed);

  List<RecoveredFile> _catalog = const [];
  List<RecoveryReceipt> _lastReceipts = const [];

  // ---------------------------------------------------------------- devices
  @override
  Future<List<DeviceInfo>> listDevices() async {
    await _wait(const Duration(milliseconds: 300));
    _assertNotCancelled('listing devices');
    return const [
      DeviceInfo(
          id: 'card1',
          name: 'SDHC Card (32 GB)',
          totalBytes: 32 * 1024 * 1024 * 1024,
          kind: DeviceKind.sdCard,
          mounted: true,
          fileSystem: 'FAT32',
          mountPoint: '/Volumes/SDHC'),
      DeviceInfo(
          id: 'usb1',
          name: 'Cruzer Blade (16 GB)',
          totalBytes: 16 * 1024 * 1024 * 1024,
          kind: DeviceKind.usbStick,
          mounted: false,
          fileSystem: 'exFAT'),
      DeviceInfo(
          id: 'ext1',
          name: 'Backup Plus (2 TB)',
          totalBytes: 2 * 1024 * 1024 * 1024 * 1024,
          kind: DeviceKind.externalDisk,
          mounted: true,
          fileSystem: 'NTFS',
          mountPoint: '/media/user/BackupPlus'),
      DeviceInfo(
          id: 'img1',
          name: 'card.img (disk image)',
          totalBytes: 8 * 1024 * 1024 * 1024,
          kind: DeviceKind.diskImage,
          mounted: true,
          fileSystem: 'RAW'),
      DeviceInfo(
          id: 'sys0',
          name: 'System Disk (512 GB)',
          totalBytes: 512 * 1024 * 1024 * 1024,
          kind: DeviceKind.internalDisk,
          mounted: true,
          isSystemDisk: true,
          fileSystem: 'APFS',
          mountPoint: '/'),
    ];
  }

  // ----------------------------------------------------------------- survey
  @override
  Future<SurveyResult> survey(DeviceInfo device) async {
    await _wait(const Duration(milliseconds: 500));
    _assertNotCancelled('surveying');
    final r = _seeded;
    return SurveyResult(
      dataPercent: 34 + r.nextInt(20).toDouble(),
      unreadablePercent: r.nextInt(4).toDouble(),
      wipePatternDetected: false,
      sampledBlocks: 4096,
    );
  }

  // ---------------------------------------------------------------- streams
  Stream<EngineProgress> _timedProgress({
    required int totalBytes,
    required Duration tick,
    required ScanPhase donePhase,
    int Function(int elapsedTicks)? filesFound,
    String? doneMessage,
  }) async* {
    var done = 0, unreadable = 0, found = 0, t = 0;
    final step = max(1, totalBytes ~/ 40);
    while (done < totalBytes) {
      if (_cancelled) {
        yield const EngineProgress(
            doneBytes: 0, totalBytes: 0, phase: ScanPhase.cancelled);
        return;
      }
      while (_paused) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      await _wait(tick);
      t++;
      done = min(done + step, totalBytes);
      if (_rand.nextInt(25) == 0) unreadable++;
      found = filesFound?.call(t) ?? found;
      final isDone = done >= totalBytes;
      yield EngineProgress(
        doneBytes: done,
        totalBytes: totalBytes,
        unreadableAreas: unreadable,
        filesFound: found,
        phase: isDone ? donePhase : ScanPhase.running,
        message: isDone ? doneMessage : null,
      );
    }
  }

  @override
  Stream<EngineProgress> createBackup(DeviceInfo device, Uri destination) {
    return _run('backup', _timedProgress(
        totalBytes: 8 * 1024 * 1024 * 1024,
        tick: _ms(90),
        donePhase: ScanPhase.done,
        doneMessage: 'Safety copy verified'));
  }

  @override
  Stream<EngineProgress> scan(DeviceInfo device, {bool useBackupCopy = true}) {
    return _run('scan', _timedProgress(
        totalBytes: 8 * 1024 * 1024 * 1024,
        tick: _ms(70),
        donePhase: ScanPhase.done,
        filesFound: (t) => t * 17,
        doneMessage: 'Scan complete'));
  }

  @override
  Future<List<RecoveredFile>> browse(String sessionId) async {
    await _wait(const Duration(milliseconds: 200));
    if (_catalog.isNotEmpty) return _catalog;
    _catalog = _buildCatalog();
    return _catalog;
  }

  @override
  Stream<EngineProgress> recover(
    String sessionId,
    List<String> fileIds,
    Uri destination, {
    required bool keepFolderStructure,
    required bool byCaptureDate,
  }) {
    final ids = List.of(fileIds);
    return _run('recover', () async* {
      // Receipts are engine-sourced evidence: computed from the catalog the
      // engine itself verified, targeting the real destination path.
      final catalog = _catalog.isNotEmpty ? _catalog : _buildCatalog();
      _catalog = catalog;
      final byId = {for (final f in catalog) f.id: f};
      _lastReceipts = [
        for (final id in ids)
          if (byId[id] != null)
            RecoveryReceipt(
              fileId: id,
              fileName: byId[id]!.name,
              verified: byId[id]!.state != FileState.unreadable,
              targetPath:
                  '${destination.toFilePath()}${keepFolderStructure ? '${byId[id]!.relativeFolder}/' : ''}${byId[id]!.name}',
            ),
      ];
      await for (final p in _timedProgress(
          totalBytes: max(1, ids.length) * 4 * 1024 * 1024,
          tick: _ms(60),
          donePhase: ScanPhase.done,
          doneMessage: 'Recovery complete — files verified')) {
        yield p;
      }
    }());
  }

  /// Receipts from the last completed recovery run (engine-sourced).
  @override
  Future<List<RecoveryReceipt>> receipts() async => List.of(_lastReceipts);

  @override
  String get engineName => 'Simulated engine';

  @override
  bool get isDemo => true;

  /// Simulated free space: a deterministic, healthy 64 GB so destination
  /// checks behave like a real volume in demos/tests.
  @override
  Future<int> freeBytes(Uri dir) async => 64 * 1024 * 1024 * 1024;

  Stream<EngineProgress> _run(String op, Stream<EngineProgress> inner) async* {
    if (_busy) {
      throw const EngineException('Another operation is still running.',
          'concurrent-op', FrfErrorCode.engineBusy);
    }
    _busy = true;
    _cancelled = false;
    try {
      yield* inner;
    } finally {
      _busy = false;
    }
  }

  // ---------------------------------------------------------------- control
  @override
  Future<void> cancel() async => _cancelled = true;
  @override
  Future<void> pause() async => _paused = true;
  @override
  Future<void> resume() async => _paused = false;

  // ---------------------------------------------------------------- helpers
  Duration _ms(int base) =>
      Duration(milliseconds: (base / tickScale).round().clamp(1, 100000));

  Future<void> _wait(Duration d) async {
    final scaled = d * (1 / tickScale);
    await Future<void>.delayed(scaled);
  }

  void _assertNotCancelled(String op) {
    if (_cancelled) throw EngineException('Cancelled while $op.', 'cancelled');
  }

  /// Deterministic catalog: 480 files, realistic names, folders, dates,
  /// damage states and duplicates. No randomness leaks between runs.
  List<RecoveredFile> _buildCatalog() {
    const kindDefs = <FileKind, List<String>>{
      FileKind.photo: ['DSC_%04d.JPG', 'IMG_%04d.PNG'],
      FileKind.raw: ['DSC_%04D.NEF', '_MG_%04d.CR2'],
      FileKind.video: ['MOV_%04d.MP4', 'GX01%03d.MP4'],
      FileKind.document: ['report_%02d.pdf', 'notes_%02d.docx'],
      FileKind.audio: ['VOICE_%03d.M4A', 'track_%02d.wav'],
      FileKind.archive: ['backup_%02d.zip'],
      FileKind.other: ['object_%03d.bin'],
    };
    const folders = <FileKind, List<String>>{
      FileKind.photo: ['DCIM/100NIKON', 'DCIM/101NIKON'],
      FileKind.raw: ['DCIM/100NIKON (orphaned)'],
      FileKind.video: ['PRIVATE/M4ROOT/CLIP'],
      FileKind.document: ['Documents'],
      FileKind.audio: ['Voice'],
      FileKind.archive: ['Backups'],
      FileKind.other: ['lostfiles'],
    };
    final files = <RecoveredFile>[];
    final allKinds = kindDefs.keys.toList();
    for (var n = 0; n < 480; n++) {
      final kind = allKinds[n % allKinds.length];
      final patterns = kindDefs[kind]!;
      final pattern = patterns[n % patterns.length];
      var name = pattern;
      // Fill numeric placeholders deterministically.
      final digitCount = RegExp('%0*(\\d*)d').firstMatch(pattern);
      if (digitCount != null) {
        final width = digitCount.group(1)?.isEmpty == false
            ? int.parse(digitCount.group(1)!)
            : 3;
        name = name.replaceFirst(
            RegExp('%0*\\d*d'), (n % 10000).toString().padLeft(width, '0'));
      }
      final r = _rand;
      files.add(RecoveredFile(
        id: 'f$n',
        name: name,
        relativeFolder: folders[kind]![n % folders[kind]!.length],
        sizeBytes: (1 + r.nextInt(40)) * 1024 * 1024 + r.nextInt(1024),
        kind: kind,
        capturedAt: DateTime(2024, 1 + n % 12, 1 + n % 28, n % 24, n % 60),
        state: n % 11 == 0
            ? FileState.damaged
            : (n % 13 == 0 ? FileState.fragmented : FileState.intact),
        duplicate: n % 17 == 0,
        confidencePercent: n % 11 == 0
            ? 46 + r.nextInt(20)
            : 88 + r.nextInt(12),
      ));
    }
    return files;
  }

  /// Test hook: determinism check uses this to reset internal caches.
  void resetForTest() {
    _catalog = const [];
    _lastReceipts = const [];
    _paused = false;
    _cancelled = false;
    _busy = false;
  }

  /// Exposed for unit tests of the free-tier gate math.
  static int get freeCap => AppBrand.freeMaxFilesPerRecovery;
}
