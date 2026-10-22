# Files Recovery FREE

[![Build All Platforms](https://github.com/LabLaunchPad/files-recovery-free/actions/workflows/build-all.yml/badge.svg)](https://github.com/LabLaunchPad/files-recovery-free/actions/workflows/build-all.yml)

**Find lost files. Scan free. Recover safely.**

A cross-platform file-recovery wizard built with Flutter — one codebase,
five native platforms: **Windows · macOS · Linux · Android · iOS** (plus
Flutter Web).

Inspired by the UX of macOS-only recovery tools (six-step guided wizard),
rebuilt from scratch with original code, wording and visuals so it is safe
to publish.

---

## Product model

| Tier | What you get |
|------|--------------|
| **Free** | Unlimited *scanning* + recovery of up to **25 files per run** |
| **Pro ($29 one-time)** | Unlimited recovery, all platforms, one key |

Brand strings and tier limits live in exactly one file:
`lib/app_brand.dart` (`AppBrand.freeMaxFilesPerRecovery = 25`,
`AppBrand.proPrice = '$29'`).

## The six-step wizard

1. **Choose** — pick the drive/card that lost files (system disk is locked
   with an explanation and can never be scanned)
2. **Survey** — a quick block sample: how much data, how much unreadable
   (DriveMap heatmap)
3. **Back up** — optional bit-for-bit safety copy before any deep scan
4. **Scan** — block-by-block search with live found-count, unreadable
   counter, cancel support
5. **Look** — browse results with condition badges
   (Intact / Damaged / Fragmented / Unreadable / Duplicate), search and
   filters
6. **Recover** — write files out and verify each one (per-file receipts)

## Architecture

```
lib/
  app_brand.dart        <- ONE source of truth: name, price, free-tier limits
  design/tokens.dart    <- colors / spacing / radii / flavors / viewport classes
  engine/
    recovery_engine.dart    <- THE boundary interface (streams, cancel, typed errors)
    simulated_engine.dart   <- Phase 1: deterministic fixture engine
  state/recovery_session.dart <- wizard state machine (pure Dart, unit-tested)
  screens/…             <- 6 wizard steps + adaptive shell + license sheet
  widgets/core.dart     <- shared components (DriveMap, BlockBar, DotWave,
                           FileBadge, StatCard, StepDots, WizardActions…)
  l10n/app_strings.dart <- every user-facing string (English)
```

**Phase 2 (shipped):** the Rust carving core is live behind the same
`RecoveryEngine` contract — `FfiRecoveryEngine` via dart:ffi. The entire
UI + test suite runs unchanged against real block-level scanning.

## Verification (all green — evidence in [`evidence/`](evidence/))

| Gate | Result |
|------|--------|
| `flutter analyze` | **0 issues** |
| `flutter test` | **50/50 passed** (18 engine/session unit + 6 widget incl. full e2e walkthrough + 26 golden screenshots) |
| Golden matrix | 4 viewports (phone-portrait / phone-landscape / tablet / desktop) × 6 steps + license sheet + receipt — all pass, deterministic |
| `flutter build web --release` | ✓ + full interactive browser walkthrough (12 evidence screenshots) |
| `flutter build linux --release` | ✓ native GTK binary, launched live under Xvfb, real pointer interaction captured |
| Android / iOS / macOS / Windows | CI (`.github/workflows/build-all.yml`) builds all five on push to `main` / tags (`v*`); bundles attach to the auto-created GitHub Release `build-<run number>` (works around private-repo Actions storage quota) |

## Build & run

```bash
flutter pub get
flutter test                 # 50 checks
flutter build web --release  # static site in build/web
flutter build linux --release
flutter build apk --release  # needs Android SDK
flutter build macos --release
flutter build windows --release
flutter build ios --release  # needs macOS + Xcode
```

Run the web build anywhere: `python3 -m http.server 8000 -d build/web`

## Regenerating golden screenshots

```bash
flutter test --update-goldens test/golden_test.dart
```

## Phase 2 — the real engine is here

`rust/` is a two-crate workspace loaded through `dart:ffi`:

```
rust/
  crates/recovery-core   signature carving: aho-corasick headers, memchr
                         footers, size-field extraction, follow-up footer
                         search, duplicate fingerprints, survey / backup /
                         recover+verify — all behind a BlockSource trait
  crates/recovery-ffi    stable C ABI: sync workers, poll-based events,
                         engine state finalized exactly at terminal delivery
```

Run the real engine (Linux bundles ship the dylib; macOS/Windows via CI):

```bash
cargo test --manifest-path rust/Cargo.toml --workspace   # 14 engine tests
flutter test                                             # 95 tests incl. FFI
flutter run -d linux --dart-define=FRF_ENGINE_FFI=true
```

### Phase 3 — real devices, cross-compiled engine, honest destinations

- **Device enumeration** (read-only, never elevated): IOKit `IOMedia` on
  macOS, SetupAPI + zero-access IOCTLs on Windows, sysfs + mountinfo on
  Linux/Android — partitions, mounts, filesystems, system-disk lock — fed
  through the same `frf_source_*` C ABI.
- **Engine cross-compile**: `cargo-ndk` ships the engine inside the Android
  APK (arm64-v8a / armeabi-v7a / x86_64) with 16 KB page-size linker flags;
  iOS builds ship a `librecovery_core_ffi.xcframework` (device + simulator).
- **16 KB page-size gate**: `scripts/check_16kb_pagesize.py` asserts every
  `lib/**/*.so` in the APK (self-tested; positive and negative controls) —
  the Play requirement that blocks non-compliant updates from 2027-02-01.
- **Destination flow**: native folder pickers (`file_selector`), per-OS
  defaults instead of hardcoded `/tmp`, engine-sourced free space
  (`frf_free_bytes`), writability probe, and a hard guard against
  recovering onto the source drive.

Without the define (or without the dylib) the app falls back to the
simulated engine — zero regression for existing bundles.
See `docs/phase2_gap_analysis.md` for the REA-assisted gap analysis and
`docs/PLATFORMS.md` for the per-OS playbooks and the landed Phase 3 ledger.

## Repository layout

This repo root **is** the Flutter project. Extra directories:

| Path | Contents |
|------|----------|
| `evidence/` | Verification artifacts — test logs, 12-shot interactive web walkthrough, live Linux desktop session, brand icons |
| `docs/` | `Files_Recovery_FREE_Verification_Report.pdf` — the 10-page verification report |
| `docs/PLATFORMS.md` | Per-OS playbooks (Windows/macOS/Linux/Android/iOS/Web), Phase 3 engine stack decisions, trust checklist |
| `docs/PERMISSIONS.md` | Permission pack: what each edition asks for and why, with the CI regression guard |
| `docs/phase2_gap_analysis.md` | REA gap analysis of the Rust engine phase |

## Legal notes

- Original implementation: flows inspired by competitor UX research, but
  all code, strings, visuals and the brand are original.
- The name "Files Recovery FREE" is descriptive; if a store review objects
  (Apple guideline 2.3.7), change `AppBrand.storeDisplayName` — one line.
- Phase 1 engine is a **simulation** and says so in the UI (watermark);
  no real drive access until the Rust core lands.
- Platform-specific tailoring decisions (privileges, packaging, filesystem
  behavior, store policies) are tracked in [`docs/PLATFORMS.md`](docs/PLATFORMS.md).
