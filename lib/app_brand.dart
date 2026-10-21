// app_brand.dart — single source of truth for every brand / monetization
// constant. Changing the product name or the free-tier limits is a ONE-LINE
// edit here; nothing else in the app hard-codes these values.
library;

class AppBrand {
  AppBrand._();

  /// Legal / internal product name.
  static const String productName = 'Files Recovery FREE';

  /// Name shown in windows, menus, installers. Keep in sync with
  /// macos/Runner/Info.plist (CFBundleDisplayName), Windows runner
  /// (main.cpp window title), linux/my_application.cc (gtk_window_set_title),
  /// Android label (AndroidManifest.xml), iOS Info.plist.
  static const String storeDisplayName = 'Files Recovery FREE';

  static const String tagline = 'Find lost files. Scan free. Recover safely.';
  static const String simulationWatermark =
      'SIMULATION ENGINE — demo data, no real drive access yet';

  /// Free tier: scanning is always free; recovery is capped per run.
  static const int freeMaxFilesPerRecovery = 25;

  /// One-time unlock price (matches the benchmark product's model).
  static const String proPrice = r'$29';

  /// Simulated license key format: FRF-XXXX-XXXX (X = base32 A-Z2-7).
  static const String licensePrefix = 'FRF';

  static const String version = '1.0.0';
  static const String website = 'https://filesrecovery.example';
}

/// Convenience helpers shared by UI and tests.
class FreeTier {
  FreeTier._();

  static bool needsUpgrade(int fileCount) =>
      fileCount > AppBrand.freeMaxFilesPerRecovery;

  static String capMessage(int count) =>
      'Free recovery is limited to ${AppBrand.freeMaxFilesPerRecovery} files '
      'per run. You selected $count — unlock Pro for unlimited recovery.';
}
