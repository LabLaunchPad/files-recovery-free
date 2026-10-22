// engine/error_codes.dart — the unified error-code map (REA quick win).
//
// One taxonomy for every failure the wizard can surface:
//   Rust ABI codes (FrfEvent.error_code / recovery-core::error_codes)
//     -> OS-level refinement via message patterns (errno text)
//     -> stable wire codes for logs
//     -> per-OS remediation hints (research-verified: docs/PLATFORMS.md)
//
// Rule: userMessage stays calm and safe to display verbatim; the code is
// machine-readable; the hint tells the user exactly what to do on THEIR OS.
// Never collapse everything into one string again.
library;

/// Error classes the UI and logs can branch on. [wire] values are stable
/// API: they may appear in logs, receipts and support conversations.
enum FrfErrorCode {
  /// No failure (progress/terminal events carry code 0 in the ABI).
  none('FRF_OK'),

  /// The source disappeared between listing and reading (unplugged, ejected).
  sourceMissing('FRF_E_SOURCE_MISSING'),

  /// Mid-stream read failure: bad blocks, dying media, cable.
  sourceUnreadable('FRF_E_SOURCE_UNREADABLE'),

  /// The OS refused access (errno EACCES/EPERM/EINVAL family).
  permissionDenied('FRF_E_PERMISSION_DENIED'),

  /// Destination not writable: read-only volume, invalid path.
  destinationInvalid('FRF_E_DESTINATION_INVALID'),

  /// Destination ran out of space (ENOSPC).
  destinationFull('FRF_E_DESTINATION_FULL'),

  /// The engine cannot make sense of this source (truncated image, raw gibberish).
  invalidSource('FRF_E_INVALID_SOURCE'),

  /// Another engine operation is still running (ABI CONCURRENT).
  engineBusy('FRF_E_ENGINE_BUSY'),

  /// Internal contract violation (ABI INVALID_ARG) — a bug, report it.
  invalidArg('FRF_E_INVALID_ARG'),

  /// Cooperative cancel completed.
  cancelled('FRF_E_CANCELLED'),

  /// Anything the map cannot classify yet.
  unknown('FRF_E_UNKNOWN');

  const FrfErrorCode(this.wire);

  final String wire;
}

/// ABI codes from recovery-core::error_codes (FrfEvent.error_code).
const int frfAbiOk = 0;
const int frfAbiIo = 1;
const int frfAbiCancelled = 2;
const int frfAbiInvalidSource = 3;
const int frfAbiConcurrent = 4;
const int frfAbiInvalidArg = 5;

/// The map: ABI code + engine/OS message text -> one typed code.
/// IO failures are refined by errno text because the ABI only says "IO".
FrfErrorCode classify({int abiCode = frfAbiOk, String message = ''}) {
  final m = message.toLowerCase();
  switch (abiCode) {
    case frfAbiCancelled:
      return FrfErrorCode.cancelled;
    case frfAbiConcurrent:
      return FrfErrorCode.engineBusy;
    case frfAbiInvalidSource:
      return FrfErrorCode.invalidSource;
    case frfAbiInvalidArg:
      return FrfErrorCode.invalidArg;
    case frfAbiIo:
      return _refineIo(m);
    case frfAbiOk:
      return _refineTextOnly(m);
    default:
      return _refineIo(m);
  }
}

FrfErrorCode _refineIo(String m) {
  if (_any(m, ['permission denied', 'access denied', 'os error 13', 'os error 5', 'eacces', 'eperm', 'not permitted'])) {
    return FrfErrorCode.permissionDenied;
  }
  if (_any(m, ['read-only', 'erofs', 'os error 30', 'is a directory', 'os error 21'])) {
    return FrfErrorCode.destinationInvalid;
  }
  if (_any(m, ['no space', 'enospc', 'os error 28', 'disk quota'])) {
    return FrfErrorCode.destinationFull;
  }
  if (_any(m, ['no such file', 'not found', 'os error 2', 'enoent', 'cannot open'])) {
    return FrfErrorCode.sourceMissing;
  }
  return FrfErrorCode.sourceUnreadable;
}

FrfErrorCode _refineTextOnly(String m) {
  if (m.isEmpty) return FrfErrorCode.none;
  if (_any(m, ['cancelled'])) return FrfErrorCode.cancelled;
  if (_any(m, ['concurrent', 'another operation'])) return FrfErrorCode.engineBusy;
  if (_any(m, ['empty', 'nothing selected', 'nothing to'])) {
    return FrfErrorCode.invalidArg;
  }
  return _refineIo(m);
}

bool _any(String haystack, List<String> needles) =>
    needles.any(haystack.contains);

/// Per-OS remediation hints. Null when nothing OS-specific helps.
/// Grounded in the Task 7 platform research (docs/PLATFORMS.md):
///  - Windows: physical volumes need the elevated helper; images do not.
///  - macOS: Full Disk Access gates arbitrary file/volume reads.
///  - Linux: block nodes are root:disk 0660 -> disk group or an image.
///  - Android: SAF/MediaStore paths need no permissions; raw access does not exist.
///  - iOS: companion edition only (no block-device API by design).
String? remediationFor(FrfErrorCode code, {required String os}) {
  switch (code) {
    case FrfErrorCode.permissionDenied:
      switch (os) {
        case 'macos':
          return 'Grant Full Disk Access to this app in System Settings '
              '→ Privacy & Security, then try again. Disk images do not '
              'need it.';
        case 'linux':
          return 'Block devices are readable by the disk group. Add your '
              'user to it, run from a session that is in it, or scan a '
              'disk image instead.';
        case 'windows':
          return 'Disk image and backup scans run without elevation. '
              'Physical-volume scans need the elevated helper.';
        case 'android':
          return 'Pick a location through the system file picker (SAF) or '
              'scan a mounted storage device.';
        case 'ios':
          return 'On-device raw scanning is not possible on iOS — use the '
              'desktop editions for deep scans.';
        default:
          return null;
      }
    case FrfErrorCode.sourceMissing:
      return 'Reconnect the drive (or re-add the image) and refresh the '
          'device list.';
    case FrfErrorCode.sourceUnreadable:
      return 'If this drive is failing, stop using it and make a safety '
          'copy first — scanning a failing drive makes things worse.';
    case FrfErrorCode.destinationInvalid:
      return 'Choose a destination folder on a writable volume with room '
          'for the recovered files.';
    case FrfErrorCode.destinationFull:
      return 'Free up space on the destination drive (or pick another '
          'one), then recover again.';
    case FrfErrorCode.invalidSource:
      return 'That image looks incomplete or not a raw disk image. Try '
          'the full original file.';
    case FrfErrorCode.engineBusy:
      return 'Wait for the current operation to finish or cancel it '
          'first.';
    case FrfErrorCode.cancelled:
      return null;
    case FrfErrorCode.invalidArg:
    case FrfErrorCode.unknown:
    case FrfErrorCode.none:
      return null;
  }
}
