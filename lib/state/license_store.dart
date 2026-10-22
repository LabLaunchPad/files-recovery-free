// state/license_store.dart — Pro-key persistence (purchase plumbing).
//
// The license survives app restarts via shared_preferences on every
// platform. The store is an injectable interface so tests use an
// in-memory fake and the session never touches the plugin directly.
//
// Only Ed25519-SIGNED keys are persisted — the simulated engine's
// format-only dev keys are session-scoped by design, so demo unlocks can
// never masquerade as a purchase on a real build.

library;

import 'package:shared_preferences/shared_preferences.dart';

abstract interface class LicenseStore {
  Future<String?> load();
  Future<void> save(String key);
  Future<void> clear();
}

class InMemoryLicenseStore implements LicenseStore {
  String? _key;
  @override
  Future<String?> load() async => _key;
  @override
  Future<void> save(String key) async => _key = key;
  @override
  Future<void> clear() async => _key = null;
}

class SharedPrefsLicenseStore implements LicenseStore {
  static const String _kKey = 'frf.pro.license_key';

  @override
  Future<String?> load() async =>
      (await SharedPreferences.getInstance()).getString(_kKey);

  @override
  Future<void> save(String key) async =>
      (await SharedPreferences.getInstance()).setString(_kKey, key);

  @override
  Future<void> clear() async =>
      (await SharedPreferences.getInstance()).remove(_kKey);
}
