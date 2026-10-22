// test/platform_pack_test.dart — the permission pack regression guard.
// Research-verified per-OS decisions (docs/PERMISSIONS.md + docs/PLATFORMS.md):
//   - macOS Release build ships WITHOUT App Sandbox (raw volume reads) and
//     without the network-server entitlement (offline trust claim).
//   - Windows stays asInvoker (explicit; elevated helper only for physical
//     volume scans, never the app itself).
//   - Android keeps ZERO uses-permission entries (Play policy: honest
//     MediaStore/SAF-only free mode; never MANAGE_EXTERNAL_STORAGE).
// These tests read the checked-in platform files so a future `flutter
// create` regeneration or careless edit cannot silently revert the pack.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // `flutter test` runs with the project root as the working directory.
  final root = Directory.current.path;

  String read(String rel) => File('$root/$rel').readAsStringSync();

  group('macOS entitlements', () {
    test('Release.entitlements has NO app sandbox', () {
      final xml = read('macos/Runner/Release.entitlements');
      expect(xml.contains('com.apple.security.app-sandbox'), isFalse,
          reason: 'sandboxed builds cannot read raw volumes or arbitrary '
              'files — Mac App Store is out of scope for this product');
    });

    test('Release.entitlements has NO network server entitlement', () {
      final xml = read('macos/Runner/Release.entitlements');
      expect(xml.contains('com.apple.security.network.server'), isFalse,
          reason: 'the app is offline-first: no telemetry, no uploads, '
              'no listening sockets');
    });

    test('Release.entitlements is still a valid plist skeleton', () {
      final xml = read('macos/Runner/Release.entitlements');
      expect(xml, contains('<plist version="1.0">'));
      expect(xml, contains('<dict>'));
      expect(xml, contains('</dict>'));
    });
  });

  group('Windows manifest', () {
    test('declares requestedExecutionLevel asInvoker explicitly', () {
      final xml = read('windows/runner/runner.exe.manifest');
      expect(xml.contains('requestedExecutionLevel'), isTrue,
          reason: 'explicit asInvoker: UAC prompt must never appear for '
              'image/backup scans');
      expect(xml.contains('requireAdministrator'), isFalse);
      expect(xml.contains('highestAvailable'), isFalse);
      expect(xml.contains('level="asInvoker"'), isTrue);
    });

    test('keeps PerMonitorV2 dpi awareness', () {
      final xml = read('windows/runner/runner.exe.manifest');
      expect(xml.contains('PerMonitorV2'), isTrue);
    });
  });

  group('Android manifest', () {
    late final String xml;
    setUpAll(() => xml = read('android/app/src/main/AndroidManifest.xml'));

    test('requests ZERO permissions (honest free mode)', () {
      expect(xml.contains('<uses-permission'), isFalse,
          reason: 'MediaStore trash + SAF flows need no permission grants; '
              'MANAGE_EXTERNAL_STORAGE would violate Play policy for the '
              'promised experience');
    });

    test('never opts into external-storage management', () {
      expect(xml.contains('MANAGE_EXTERNAL_STORAGE'), isFalse);
      expect(xml.contains('READ_EXTERNAL_STORAGE'), isFalse);
      expect(xml.contains('WRITE_EXTERNAL_STORAGE'), isFalse);
    });
  });

  group('Documentation', () {
    test('PERMISSIONS.md exists and covers all six platforms', () {
      final md = read('docs/PERMISSIONS.md');
      final lower = md.toLowerCase();
      for (final os in ['Windows', 'macOS', 'Linux', 'Android', 'iOS', 'Web']) {
        expect(md.contains(os), isTrue, reason: 'PERMISSIONS.md must cover $os');
      }
      expect(lower.contains('read-only'), isTrue,
          reason: 'the read-only promise is the core trust claim');
    });
  });
}
