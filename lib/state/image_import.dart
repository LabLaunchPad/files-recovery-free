// state/image_import.dart — disk-image import flow (Phase 4).
//
// "Scan a disk image" is the safest way to recover: the user points at a
// `.img`/`.dd`/backup file and the engine reads it like any other block
// source. On desktop the picked file is a real path; on Android the system
// document picker often returns a `content://` URI that dart:io cannot
// open, so the SAF bridge streams the bytes into the app cache first and
// the engine scans the cached copy (read-only, never re-uploaded).
//
// Pure decision logic ([SafBridge.needsIngest]) is static so it can be
// unit-tested without a device; the MethodChannel call is injectable.

library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';

/// The platform file picker used by the import flow. Injectable for tests.
typedef ImageFilePicker = Future<String?> Function();

/// Default picker: native open-file dialog on every desktop; the Android
/// system document picker (SAF) on mobile. Web has no file-path concept
/// for the engine — callers hide the import entry on kIsWeb.
Future<String?> platformPickImageFile() async {
  if (kIsWeb) return null;
  try {
    final file = await openFile();
    return file?.path;
  } on Exception {
    return null; // unsupported platform / user-agent → treated as cancel
  }
}

/// Android SAF ingestion bridge: materializes a `content://` document into
/// the app cache so the engine can open it by path. No-op elsewhere.
///
/// [androidOverride] pins the "this is Android" facet for tests (the
/// decision otherwise reads Platform.isAndroid, which is false on the
/// test host).
class SafBridge {
  SafBridge({MethodChannel? channel, bool? androidOverride})
      : _channel = channel ?? const MethodChannel('frf/saf'),
        _androidOverride = androidOverride;

  final MethodChannel _channel;
  final bool? _androidOverride;

  static const String ingestFailed =
      'That file could not be opened for scanning. Try moving it to your '
      'Downloads folder and importing again.';

  static bool looksLikeContentUri(String path) => path.startsWith('content://');

  bool get _isAndroid => _androidOverride ?? (!kIsWeb && Platform.isAndroid);

  /// True when [path] cannot be opened directly by the engine and must go
  /// through SAF ingestion first: content URIs are NEVER directly openable
  /// (on any platform, defensively); plain paths only on Android, and only
  /// when dart:io cannot see them (SAF-mediated documents).
  bool shouldIngest(String path) {
    if (looksLikeContentUri(path)) return true;
    if (!_isAndroid) return false;
    try {
      return !File(path).existsSync();
    } catch (_) {
      return true;
    }
  }

  /// Streams the SAF document into `cacheDir/frf_import/` and returns the
  /// cached copy's absolute path.
  Future<String> ingestToCache(String uri) async {
    final cached =
        await _channel.invokeMethod<String>('ingestToCache', {'uri': uri});
    if (cached == null || cached.isEmpty) {
      throw StateError('SAF ingest returned no path');
    }
    return cached;
  }
}
