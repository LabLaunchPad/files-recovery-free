// engine/ffi_entry.dart — platform seam for the FFI engine.
// Native targets (VM / Android / iOS / desktop) compile the real
// dart:ffi engine; the web build compiles the unsupported stub instead,
// keeping `flutter build web` working since the engine landed in Phase 2.
library;

export 'ffi_engine_unsupported.dart'
    if (dart.library.ffi) 'ffi_engine.dart';
