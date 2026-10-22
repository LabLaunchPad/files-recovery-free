// test/error_codes_test.dart — the unified error-code map (REA quick win).
// Locks the ABI-code + errno-text classification and the per-OS remediation
// matrix so error surfacing can never regress to one collapsed string.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:files_recovery_free/engine/recovery_engine.dart';

void main() {
  group('classify() — ABI codes', () {
    test('cancelled / concurrent / invalid map 1:1 to typed codes', () {
      expect(
          classify(abiCode: frfAbiCancelled, message: 'user pressed stop'),
          FrfErrorCode.cancelled);
      expect(
          classify(abiCode: frfAbiConcurrent, message: 'whatever'),
          FrfErrorCode.engineBusy);
      expect(
          classify(abiCode: frfAbiInvalidSource, message: 'not an image'),
          FrfErrorCode.invalidSource);
      expect(
          classify(abiCode: frfAbiInvalidArg, message: 'bad call'),
          FrfErrorCode.invalidArg);
    });

    test('ok with no message means no failure', () {
      expect(classify(abiCode: frfAbiOk, message: ''), FrfErrorCode.none);
    });

    test('ok with text-only failures still classifies', () {
      expect(
          classify(abiCode: frfAbiOk, message: 'operation was cancelled'),
          FrfErrorCode.cancelled);
      expect(
          classify(abiCode: frfAbiOk, message: 'another operation is running'),
          FrfErrorCode.engineBusy);
      expect(
          classify(abiCode: frfAbiOk, message: 'nothing selected'),
          FrfErrorCode.invalidArg);
    });
  });

  group('classify() — IO refinement via errno text', () {
    test('permission family', () {
      for (final m in [
        'cannot create backup: Permission denied (os error 13)',
        'read_at failed: Access is denied. (os error 5)',
        'EACCES while opening source',
      ]) {
        expect(classify(abiCode: frfAbiIo, message: m),
            FrfErrorCode.permissionDenied, reason: m);
      }
    });

    test('read-only destination family', () {
      expect(
          classify(
              abiCode: frfAbiIo,
              message: 'cannot write: Read-only file system (os error 30)'),
          FrfErrorCode.destinationInvalid);
    });

    test('disk full family', () {
      expect(
          classify(
              abiCode: frfAbiIo,
              message: 'backup write failed: No space left on device (os error 28)'),
          FrfErrorCode.destinationFull);
    });

    test('missing source family', () {
      expect(
          classify(abiCode: frfAbiIo, message: 'cannot open: No such file or directory (os error 2)'),
          FrfErrorCode.sourceMissing);
    });

    test('everything else IO is sourceUnreadable', () {
      expect(
          classify(abiCode: frfAbiIo, message: 'read failed: input/output error'),
          FrfErrorCode.sourceUnreadable);
    });
  });

  group('EngineException', () {
    test('default code stays unknown (source compatible)', () {
      const e = EngineException('Something went wrong.');
      expect(e.code, FrfErrorCode.unknown);
      expect(e.technical, '');
    });

    test('fromEngine classifies ABI + message', () {
      final e = EngineException.fromEngine(
          'Could not start the scan.', 'Permission denied (os error 13)',
          abiCode: frfAbiIo);
      expect(e.code, FrfErrorCode.permissionDenied);
      expect(e.toString(), contains('FRF_E_PERMISSION_DENIED'));
    });

    test('wire codes are stable and prefixed', () {
      for (final c in FrfErrorCode.values) {
        expect(c.wire, startsWith('FRF_'), reason: c.name);
      }
      expect(FrfErrorCode.permissionDenied.wire, 'FRF_E_PERMISSION_DENIED');
      expect(FrfErrorCode.none.wire, 'FRF_OK');
    });
  });

  group('remediationFor() — per-OS hints', () {
    test('permission denied has a hint on every supported OS', () {
      for (final os in ['macos', 'linux', 'windows', 'android', 'ios']) {
        final hint = remediationFor(FrfErrorCode.permissionDenied, os: os);
        expect(hint, isNotNull, reason: os);
        expect(hint, isNotEmpty, reason: os);
      }
    });

    test('macOS hint points at Full Disk Access', () {
      expect(remediationFor(FrfErrorCode.permissionDenied, os: 'macos'),
          contains('Full Disk Access'));
    });

    test('Linux hint points at the disk group or an image', () {
      final h = remediationFor(FrfErrorCode.permissionDenied, os: 'linux')!;
      expect(h, contains('disk group'));
      expect(h, contains('image'));
    });

    test('Windows hint separates elevated scans from images', () {
      final h = remediationFor(FrfErrorCode.permissionDenied, os: 'windows')!;
      expect(h, contains('elevated'));
    });

    test('sourceUnreadable warns about failing drives', () {
      expect(remediationFor(FrfErrorCode.sourceUnreadable, os: 'macos'),
          contains('safety copy'));
    });

    test('cancelled and unknown have no noisy hint', () {
      expect(remediationFor(FrfErrorCode.cancelled, os: 'linux'), isNull);
      expect(remediationFor(FrfErrorCode.unknown, os: 'linux'), isNull);
      expect(remediationFor(FrfErrorCode.none, os: 'linux'), isNull);
    });
  });
}
