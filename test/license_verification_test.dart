// test/license_verification_test.dart — Phase 4 Ed25519 license plumbing.
//
// Covers the session-level contract: engine-mediated verification (never a
// local regex), the signed/dev distinction, persistence of SIGNED keys
// only, and startup restore with stale-key cleanup. The real Ed25519
// chain (openssl mint → Rust verify) is exercised through the FFI engine
// with the sample key below, signed by the identity whose private key is
// NOT in this repository.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:files_recovery_free/engine/recovery_engine.dart';
import 'package:files_recovery_free/engine/simulated_engine.dart';
import 'package:files_recovery_free/state/license_store.dart';
import 'package:files_recovery_free/state/recovery_session.dart';

/// Sample perpetual key minted with the repo's sample identity
/// (scripts/mint_license_key.py; private key kept off-repo).
const String sampleSignedKey =
    'FRF1-RlJG-UFJP-MQEM-UQAA-AAAA-AAAA-AADh-uwuR-/iVo-P3WD-mrXM-LQMu-'
    '/B0B-Elr1-jQf6-JYnO-0x2i-aki0-54WP-8Dtn-XBPC-Fm/A-qe1x-nyK2-aU+H-'
    '/9jE-NY7k-vk8L';

void main() {
  group('simulated engine: dev keys are format-only', () {
    late RecoverySession s;
    setUp(() => s = RecoverySession(engine: SimulatedEngine(tickScale: 500)));

    test('dev-format key unlocks but is never "signed"', () async {
      final v = await s.engine.verifyLicense('frf-abcd-2345');
      expect(v.valid, isTrue);
      expect(v.signed, isFalse);
      expect(await s.activateLicense('FRF-ABCD-2345'), isTrue);
      expect(s.licensed, isTrue);
      expect(s.licenseSigned, isFalse);
    });

    test('signed FRF1 keys do NOT verify against the simulated engine',
        () async {
      final v = await s.engine.verifyLicense(sampleSignedKey);
      expect(v.valid, isFalse,
          reason: 'the simulated engine has no Ed25519 verifier');
      expect(await s.activateLicense(sampleSignedKey), isFalse);
    });

    test('garbage is rejected without throwing', () async {
      expect(await s.activateLicense(''), isFalse);
      expect(await s.activateLicense('not a key'), isFalse);
      expect(s.licensed, isFalse);
    });
  });

  group('persistence (purchase plumbing)', () {
    test('signed keys persist; dev keys stay session-scoped', () async {
      final store = InMemoryLicenseStore();

      // A signed key (engine stubbed to accept it) lands in the store.
      final s1 = RecoverySession(
          engine: AcceptingEngine(), licenseStore: store);
      expect(await s1.activateLicense(sampleSignedKey), isTrue);
      expect(await store.load(), sampleSignedKey);

      // A dev key on the simulated engine does NOT land in the store.
      final store2 = InMemoryLicenseStore();
      final s2 = RecoverySession(
          engine: SimulatedEngine(tickScale: 500), licenseStore: store2);
      expect(await s2.activateLicense('FRF-AAAA-2222'), isTrue);
      expect(await store2.load(), isNull,
          reason: 'demo unlocks must never masquerade as purchases');
    });

    test('restoreLicense re-activates and clears stale keys', () async {
      final store = InMemoryLicenseStore();

      // Stale key that no engine accepts → dropped on restore.
      await store.save('FRF-STALE-STALE');
      final s1 = RecoverySession(engine: SimulatedEngine(tickScale: 500), licenseStore: store);
      await s1.restoreLicense();
      expect(s1.licensed, isFalse);
      expect(await store.load(), isNull);

      // Valid signed key → restored as licensed + signed.
      await store.save(sampleSignedKey);
      final s2 = RecoverySession(engine: AcceptingEngine(), licenseStore: store);
      await s2.restoreLicense();
      expect(s2.licensed, isTrue);
      expect(s2.licenseSigned, isTrue);
      expect(s2.licenseKey, sampleSignedKey);
    });

    test('restore without a store is a no-op', () async {
      final s = RecoverySession(engine: SimulatedEngine(tickScale: 500));
      await s.restoreLicense();
      expect(s.licensed, isFalse);
    });
  });
}

/// Simulated engine whose signed-key verdict is scripted for the sample
/// key (mirrors what the REAL FFI engine does — covered end-to-end by
/// test/ffi_engine_test.dart on CI).
class AcceptingEngine extends SimulatedEngine {
  @override
  Future<LicenseVerification> verifyLicense(String key) async {
    if (key.trim() == sampleSignedKey) {
      return const LicenseVerification(valid: true, signed: true);
    }
    return const LicenseVerification(valid: false, signed: false);
  }
}
