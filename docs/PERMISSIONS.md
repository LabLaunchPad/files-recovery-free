# Permission Pack — what each edition asks for, and why

> Research-verified (Task 7 fleet, 2026-10-22; sources in
> `Files_Recovery_FREE_Platform_Research_Report.docx`). This is the single
> source of truth for platform permission decisions. The regression guard
> lives in `test/platform_pack_test.dart` — a careless edit to the platform
> files fails CI.

## Ground rules (every edition)

1. **Read-only source promise.** Scans never write to the source; recovered
   files are written only to a user-chosen destination.
2. **Least privilege.** The app itself runs unprivileged everywhere. Any
   elevated/raw access is a clearly-labeled, user-initiated opt-in.
3. **No telemetry, no uploads, works offline.** No network entitlements, no
   internet permission, nothing that betrays the headline trust claim.
4. **Honest free mode.** Scanning is free; recovery caps at 25 files per
   run. Permission requests never gate the free experience behind
   alarming OS prompts.

| OS | Declared permissions | Raw-volume access | Where enforced |
|----|----------------------|-------------------|----------------|
| Windows | none (asInvoker) | elevated helper, separate process | `windows/runner/runner.exe.manifest` |
| macOS | none in Release | Full Disk Access (user grant) | `macos/Runner/Release.entitlements` |
| Linux | none | `disk` group membership or image mode | docs + error hints (`lib/engine/error_codes.dart`) |
| Android | none | not offered (Play policy) | `android/app/src/main/AndroidManifest.xml` |
| iOS | none | impossible by design (Guideline 2.5.2) | companion edition only |
| Web | none | none — OPFS/user-picked files only | PWA manifest + 2 GB demo cap |

## Windows

- `runner.exe.manifest` pins **`requestedExecutionLevel asInvoker`**
  explicitly. UAC must never appear for image/backup scans — that is the
  everyday path.
- Physical-volume scans (Phase 3) launch a **separate elevated helper**
  process; the wizard explains why, and the helper does nothing else.
- OneDrive/placeholder files (`FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS`,
  `OFFLINE`) are skipped, not recalled — no surprise downloads.
- BitLocker-locked volumes are detected in Choose and routed to an unlock
  explainer instead of a permission fight.
- Distribution target: signed MSIX + winget; EV cert later, OV first.

## macOS

- **`com.apple.security.app-sandbox` is NOT in Release.entitlements.** A
  sandboxed build cannot read raw volumes or arbitrary files, which is the
  product. The Mac App Store is out of scope; distribution is a
  hardened-runtime, notarized + stapled DMG and a Homebrew cask.
- **`com.apple.security.network.server` removed as well** — offline-first
  is a headline claim; keep the entitlements honest.
- Full Disk Access is requested **at first real scan** with a rationale
  screen, not at launch. If declined, image-mode scanning still works and
  the error-code map says so (`FRF_E_PERMISSION_DENIED` on macOS).
- DiskArbitration (Phase 3) handles volume enumeration and mount events.

## Linux

- Block nodes are `root:disk 0660`. The app enumerates via udisks2/libudev
  and reads images without any privilege; raw scans ask the user to be in
  the **`disk` group** — no setuid, no daemon, no privileged helper.
- The permission ask is an error-path hint, not a wall:
  `remediationFor(permissionDenied, os: linux)` explains the disk group or
  the image-mode alternative.
- Flatpak has no block-device portal — deb/rpm/AppImage ship first;
  Flatpak only for image-file scan mode.

## Android

- **Zero `<uses-permission>` entries.** The honest free mode reads the
  MediaStore trash (`IS_TRASHED`, ~30-day retention) and scans
  user-picked folders via SAF — both are permission-free by design.
- `MANAGE_EXTERNAL_STORAGE` is banned in this product: Play's Deceptive
  Behavior policy punishes both the permission and the promises that come
  with it. Never add it for a "full scan" claim.
- Optional root scan (if ever shipped) is a separate, clearly-labeled
  build — never the Play distribution.
- Engine notes: cargo-ndk + NDK r28, and **16 KB page-size alignment is a
  hard Play requirement from 2027-02-01** — CI asserts ELF LOAD alignment.

## iOS

- On-device carving is impossible by design (sandbox, no block-device
  API, App Review Guideline 2.5.2). The iOS edition is a companion:
  recovery education, Files-trash how-to, remote status for desktop scans.
- No special entitlements; deep scans happen on desktop, including the
  **"Scan iOS backup"** source over the MobileSync folder.

## Web

- No install, no permissions: the WASM engine (recovery-core compiled
  with wasm-pack, `BlockSource` over `File.slice`/OPFS) scans files the
  user explicitly picks. 2 GB cap, "your disk image never leaves your
  machine" as the privacy promise.

## In-app surfacing

- The **engine badge** (`EngineBadge` widget) shows which engine is
  running; simulated builds carry an amber DEMO tag (watermark gate).
- The **error-code map** (`lib/engine/error_codes.dart`) turns OS refusals
  into calm, OS-specific remediation text instead of dead ends — e.g.
  Full Disk Access on macOS, disk group on Linux, SAF on Android.
- Expectation banners (ground rule 3): per-OS engine behavior differences
  are shown in-app, never hidden.
