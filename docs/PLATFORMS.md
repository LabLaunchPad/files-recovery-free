# Platform Playbooks — tailoring each edition to its OS

> Distilled from the Task 7 deep-research fleet (five agents: Windows+macOS, Linux+Android+iOS+Web,
> competitive teardown, Rust/FFI stack, REA gap analysis), researched 2026-10-22 against primary
> sources. The full narrative with pricing charts and the 55-source register lives in
> `Files_Recovery_FREE_Platform_Research_Report.docx` (release-attached and in the project download
> bundle). Inline `[S#]` markers refer to that report's source register.

## Ground rules (all editions)

1. The wizard never promises guaranteed recovery; free = scan + recover 25 files, Pro = $29 one-time.
2. Scans are strictly read-only; recovered files are written only to a user-chosen destination.
3. Engine behavior differences per OS are surfaced in-app (expectation banners), never hidden.
4. No telemetry, no uploads, works offline — this is a headline trust claim, keep it true.

## Windows edition

- Filesystem reality: NTFS (MFT + USN change journal + `$Recycle.Bin`), ReFS/Dev Drive and exFAT are
  carving-only, VSS gives snapshot sources [S1][S3][S4][S5].
- **Keep `runner.exe.manifest` asInvoker**; launch a separate elevated helper only for physical-volume
  scans. Image/backup scans stay unprivileged.
- Skip OneDrive stubs: never open files with `FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS`/`OFFLINE` [S2].
- Detect BitLocker-locked volumes in Choose and guide unlock [S6]; explain Storage Sense bin behavior.
- Distribution: signed MSIX (`pub.dev/packages/msix`) + winget manifest PR [S8][S10]; OV cert first,
  EV later; claims stay within Store Policy 7.20 [S7][S9].
- Fluent-feel pass: taskbar progress, completion toasts, system dark mode.

## macOS edition

- APFS reality: clones (fingerprints legitimately collide), hourly local snapshots (rich scan source),
  per-volume encryption, HFS+ legacy [S14].
- **Remove `com.apple.security.app-sandbox` from `Release.entitlements`** — sandboxed builds cannot
  read raw volumes or arbitrary files; the Mac App Store is out of scope for this product [S11].
- Request Full Disk Access at first real scan with a rationale screen; degrade gracefully if declined.
- Adopt DiskArbitration for volume enumeration and mount events (closes the Phase 3 backlog item) [S13].
- Distribution: hardened-runtime, notarized + stapled DMG; Sparkle 2 Ed25519 appcasts (same signature
  stack as future license keys); Homebrew cask; Setapp for Pro [S12][S15][S16].

## Linux edition

- ext4 undelete goes through the jbd2 journal (extundelete/ext4magic technique); XFS is carving-only;
  btrfs/ZFS: snapshot discovery first [S17][S18].
- Block nodes are `root:disk 0660`; enumerate via udisks2/libudev; `disk`-group membership only for
  raw scans. No privileged helper [S20].
- **Flatpak has no block-device portal** (TestDisk/GParted are absent from Flathub) — ship deb, rpm
  and AppImage first; Flatpak only for image-file scan mode [S19].
- GNOME HIG layout conventions; ship the Rust engine as a CLI companion binary [S53][S38].

## Android edition

- Honest free mode = MediaStore trash view (`IS_TRASHED`, ~30-day retention, consent-flow restore);
  second mode = SAF folder scan; optional clearly-labeled root scan; PC-assisted deep scans via the
  desktop editions [S21][S55][S54].
- Do not request `MANAGE_EXTERNAL_STORAGE`; Play Deceptive Behavior policy bans impossible claims [S23][S24].
- Engine lands via cargo-ndk + NDK r28; **16 KB page-size alignment is a hard Play requirement —
  from 2027-02-01 non-compliant updates are blocked**; assert LOAD alignment in CI [S22][S46].

## iOS edition

- On-device carving is impossible by design (sandbox, no block-device API, Guideline 2.5.2) [S27].
- Ship a companion edition: recovery education, Files-trash how-to, remote status for desktop scans.
- The desktop editions gain a **"Scan iOS backup"** source over the MobileSync folder — the iMazing /
  Dr.Fone pattern, App-Store-safe [S26][S25].

## Web edition

- Compile `recovery-core` (FFI-free) with wasm-pack; `BlockSource` maps onto `File.slice` + OPFS;
  scan inside a Web Worker — SQLite's OPFS VFS is the precedent [S28][S29][S30].
- Privacy-first demo: "your disk image never leaves your machine"; 2 GB scan cap; Chromium-first with
  `<input type=file>` fallback; finish PWA installability.

## Phase 3 engine stack (decisions)

- **Keep the hand-rolled C ABI** (sync workers + poll events). flutter_rust_bridge 2.13 / rinf 8.11
  optimize push-style streaming we do not use; all three targets (cargo-ndk, XCFramework, wasm) sit
  on the C ABI unchanged [S39][S40].
- Filesystem crates: `mft` 0.7.0 + `ntfs-reader` 0.6.0 (NTFS/USN), `rust-fs-ext4` 0.8.0, `apfs` 0.4.1,
  `fatfs` + DIY 0xE5 scan. **Never link GPL**: apfs-fuse is GPL-2.0; Sleuth Kit is IPL/CPL+GPL and may
  only be invoked out-of-process. Add a `cargo-deny` GPL gate [S41][S42][S43][S44][S45].
- Testing: tiny deterministic fixture images checked in with hashed expected outputs; big images
  generated in CI (`fstool`, pinned UUIDs); NIST CFReDS / DigitalCorpora cached, never redistributed;
  cargo-fuzz + proptest on parsers [S47][S48][S49].
- Risks watched: crate stagnation (isolate parsers behind a trait), GPL contamination, 16 KB pages,
  iOS static-link slices, FFI backpressure (bounded ring buffer + coalesced events).

## REA gap top items (see docs/phase2_gap_analysis.md for the engine-side list)

- Critical: Windows manifest elevation strategy · macOS sandbox entitlement · Android zero
  permissions · zero `Semantics` labels anywhere in the UI.
- High: placeholder LICENSE + missing third-party notices · UI-only license gate · all errors
  collapsed to one string · fabricated receipts while `frf_receipt_*` is unbound · no signing on any
  platform · `/tmp` hardcoded destinations with the folder picker disabled · no purchase plumbing.

## Trust & distribution checklist (from the competitive teardown)

- README: CI + license badges, wizard GIF from the golden screenshots, privacy statement, install
  one-liners as channels open, CONTRIBUTING, per-release SHA256 table.
- Position against the category's dark patterns: real recovery before payment, honest per-file
  confidence states, perpetual pricing, zero pre-ticked boxes, clinical copy.
- Pricing anchor (verified 2026-10-22): Disk Drill $89, Recoverit $74.99/yr auto-renew (perpetual
  $134.99), Recuva Pro $24.95/yr, EaseUS from $69.95, R-Studio $79.99, DMDE $20 — ours: **$29
  one-time, all six platforms**.
