// main.dart — Files Recovery FREE entry point.
// Adaptive shell: Material 3 theme carries the brand; TargetPlatform decides
// scroll/selection feel so macOS/iOS feel Cupertino, Windows/Linux feel
// Fluent-adjacent, Android feels Material — one codebase, no forks.
library;

import 'package:flutter/material.dart';

import 'app_brand.dart';
import 'design/tokens.dart';
import 'engine/ffi_engine.dart';
import 'engine/recovery_engine.dart';
import 'engine/simulated_engine.dart';
import 'screens/wizard_screen.dart';
import 'state/recovery_session.dart';

/// Engine selection: `--dart-define=FRF_ENGINE_FFI=true` runs the Phase 2
/// Rust carving core (falls back to the simulated engine when the dynamic
/// library is not bundled). Default stays the simulated engine.
RecoveryEngine _selectEngine() {
  const useFfi = bool.fromEnvironment('FRF_ENGINE_FFI');
  if (useFfi) {
    final ffi = FfiRecoveryEngine.tryLoad();
    if (ffi != null) return ffi;
  }
  return SimulatedEngine();
}

void main() {
  runApp(FilesRecoveryFreeApp(session: RecoverySession(engine: _selectEngine())));
}

class FilesRecoveryFreeApp extends StatelessWidget {
  final RecoverySession session;
  const FilesRecoveryFreeApp({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: FrfColors.brandPrimary,
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: AppBrand.storeDisplayName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        fontFamily: 'Carlito',
        scaffoldBackgroundColor: FrfColors.canvas,
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: FrfColors.brandPrimary,
            foregroundColor: Colors.white,
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? FrfColors.brandPrimary
                  : null),
          trackColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? FrfColors.brandPrimary.withValues(alpha: 0.4)
                  : null),
        ),
      ),
      home: WizardScreen(session: session),
    );
  }
}
