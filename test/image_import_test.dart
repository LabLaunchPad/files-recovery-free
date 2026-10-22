// test/image_import_test.dart — Phase 4 disk-image import + raw-device UX.
//
// Covers: the SAF-ingestion decision logic, the session import flow
// (pick → optional ingest → register → refresh → select), cancel/failure
// paths, and the [DeviceInfo.isRawDevice] classification that drives the
// Choose-step deep-scan banner.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:files_recovery_free/engine/recovery_engine.dart';
import 'package:files_recovery_free/engine/simulated_engine.dart';
import 'package:files_recovery_free/state/image_import.dart';
import 'package:files_recovery_free/state/recovery_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SafBridge decision logic', () {
    test('content:// URIs always need ingestion — on any platform', () {
      expect(
          SafBridge(androidOverride: false).shouldIngest(
              'content://com.android.providers.downloads.documents/document/msf%3A1000'),
          isTrue);
      expect(SafBridge.looksLikeContentUri('content://x'), isTrue);
    });

    test('plain paths: only Android, and only when dart:io cannot see them',
        () {
      final readable = '${Directory.systemTemp.path}/frf_import_test_ok.img';
      File(readable).writeAsStringSync('x');
      addTearDown(() => File(readable).deleteSync());
      final android = SafBridge(androidOverride: true);
      expect(android.shouldIngest(readable), isFalse);
      expect(
          android.shouldIngest(
              '${Directory.systemTemp.path}/frf_never_exists_941.img'),
          isTrue);
      // Off-Android, plain paths pass through untouched.
      expect(
          SafBridge(androidOverride: false)
              .shouldIngest('/definitely/missing.img'),
          isFalse);
    });

    test('ingest failure hint is user-facing and actionable', () {
      expect(SafBridge.ingestFailed, contains('importing'));
    });
  });

  group('DeviceInfo.isRawDevice', () {
    const raw = DeviceInfo(
        id: 'raw1',
        name: 'USB Disk',
        totalBytes: 1,
        kind: DeviceKind.usbStick,
        mounted: false);
    const mounted = DeviceInfo(
        id: 'm1',
        name: 'USB Disk',
        totalBytes: 1,
        kind: DeviceKind.usbStick,
        mounted: true,
        fileSystem: 'exFAT');
    const image = DeviceInfo(
        id: 'img1',
        name: 'card.img',
        totalBytes: 1,
        kind: DeviceKind.diskImage,
        mounted: false);
    const system = DeviceInfo(
        id: 'sys',
        name: 'System',
        totalBytes: 1,
        kind: DeviceKind.internalDisk,
        mounted: true,
        isSystemDisk: true,
        fileSystem: 'APFS');

    test('unmounted without filesystem = deep scan', () {
      expect(raw.isRawDevice, isTrue);
    });
    test('mounted volume / imported image / system disk are not raw', () {
      expect(mounted.isRawDevice, isFalse);
      expect(image.isRawDevice, isFalse);
      expect(system.isRawDevice, isFalse);
    });
  });

  group('importDiskImage (session flow, simulated engine)', () {
    late RecoverySession session;

    setUp(() {
      session = RecoverySession(engine: SimulatedEngine(tickScale: 500));
    });

    test('pick → register → refresh → auto-select', () async {
      session.pickImageFile = () async => '/storage/photos.card.img';
      await session.refreshDevices();
      expect(session.devices.any((d) => d.id == 'img-user-1'), isFalse);

      await session.importDiskImage();

      expect(session.errorText, isNull);
      expect(session.importingImage, isFalse);
      expect(session.selectedDevice?.id, 'img-user-1');
      expect(session.selectedDevice?.kind, DeviceKind.diskImage);
      expect(session.selectedDevice?.sourcePath, '/storage/photos.card.img');
      expect(session.selectedDevice?.name, contains('photos.card.img'));
      // A second import of the same path reuses the source (no duplicate).
      session.selectedDevice = null;
      await session.importDiskImage();
      expect(session.selectedDevice?.id, 'img-user-1');
    });

    test('user cancel is a silent no-op', () async {
      session.pickImageFile = () async => null;
      await session.importDiskImage();
      expect(session.errorText, isNull);
      expect(session.selectedDevice, isNull);
    });

    test('SAF content URI is routed through the bridge', () async {
      final seen = <String>[];
      session.pickImageFile = () async => 'content://docs/image.dd';
      session.safBridge = FakeSafBridge(seen);
      await session.importDiskImage();
      expect(seen, ['content://docs/image.dd']);
      expect(session.selectedDevice?.sourcePath,
          '/data/cache/frf_import/1_image.dd');
    });

    test('engine failure surfaces a typed invalid-source error', () async {
      final failSession =
          RecoverySession(engine: FailingImageEngine())
            ..pickImageFile = () async => '/nowhere/broken.img';
      await failSession.importDiskImage();
      expect(failSession.errorText, isNotNull);
      expect(failSession.errorCode, FrfErrorCode.invalidSource);
      expect(failSession.importingImage, isFalse);
    });
  });
}

class FakeSafBridge extends SafBridge {
  FakeSafBridge(this.seen)
      : super(
            channel: const MethodChannel('frf/test-unused'),
            androidOverride: true);
  final List<String> seen;
  @override
  Future<String> ingestToCache(String uri) async {
    seen.add(uri);
    return '/data/cache/frf_import/1_image.dd';
  }
}

class FailingImageEngine extends SimulatedEngine {
  @override
  Future<DeviceInfo> addImageSource(String path) async {
    throw const EngineException(
        'Could not open that image.', 'test: unreadable',
        FrfErrorCode.invalidSource);
  }
}
