// design/tokens.dart — Files Recovery FREE brand tokens.
// Single source of truth. Golden tests guard these values (Blueprint Ch. 4).
import 'package:flutter/material.dart';

@immutable
class FrfColors {
  const FrfColors._();
  static const brandPrimary = Color(0xFF0F4C4C); // Deep Teal
  static const brandDark = Color(0xFF0A2E2E); // Abyss
  static const brandBright = Color(0xFF17777A); // Lagoon (interactive)
  static const rescue = Color(0xFFF5A623); // Amber — paid/destructive only
  static const ok = Color(0xFF2E9E5B);
  static const warn = Color(0xFFF5A623);
  static const bad = Color(0xFFD64545);
  static const locked = Color(0xFF8A8F98);
  static const surface = Color(0xFFFFFFFF);
  static const canvas = Color(0xFFF6F8F8);
  static const onDark = Color(0xFFEFF5F4);
  static const mutedOnLight = Color(0xFF5B6B6A);
  static const hairline = Color(0xFFDDE5E4);

  /// Block heatmap ramp for DriveMap / BlockBar (empty -> data -> unreadable).
  static const blockEmpty = Color(0xFFE4ECEB);
  static const blockData = brandPrimary;
  static const blockUnreadable = bad;
  static const blockRescued = rescue;
}

@immutable
class FrfSpacing {
  const FrfSpacing._();
  static const xs = 4.0,
      s = 8.0,
      m = 12.0,
      l = 16.0,
      xl = 24.0,
      xxl = 32.0,
      hero = 48.0;
}

@immutable
class FrfRadius {
  const FrfRadius._();
  static const control = 8.0, card = 12.0, sheet = 20.0;
}

@immutable
class FrfMotion {
  const FrfMotion._();
  static const standard = Duration(milliseconds: 200);
  static const emphasized = Duration(milliseconds: 400);
}

/// Typography scale (Inter-class system sans; falls back per platform).
@immutable
class FrfType {
  const FrfType._();
  static const display = 28.0;
  static const title = 20.0;
  static const body = 14.0;
  static const caption = 12.0;
  static const stat = 32.0;
}

/// Platform flavor: which native design language the shell renders.
/// Blueprint Chapter 3: Cupertino accents on iOS/macOS, Material 3 on
/// Android, Fluent-inspired on Windows/Linux desktop.
enum PlatformFlavor { cupertino, material, fluent }

PlatformFlavor flavorFor(TargetPlatform p) {
  switch (p) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return PlatformFlavor.cupertino;
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
      return PlatformFlavor.material;
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return PlatformFlavor.fluent;
  }
}

/// Viewport classes used by the responsive shell and the golden matrix.
enum ViewportClass { phonePortrait, phoneLandscape, tablet, desktop }

/// Very wide aspect ratios (>1.8) are phone-landscape, not tablet/desktop,
/// regardless of pixel width.
ViewportClass viewportClassFor(Size size) {
  final aspect = size.height <= 0 ? 1.0 : size.width / size.height;
  if (aspect > 1.8) return ViewportClass.phoneLandscape;
  if (size.width >= 1100) return ViewportClass.desktop;
  if (size.width >= 700) return ViewportClass.tablet;
  return ViewportClass.phonePortrait;
}
