# Phase 2 Gap Analysis — Rust Engine (REA-assisted)

**Date:** 2026-10-22 · **Scope:** what was missing between the Phase 1
simulated engine and a production-grade carving engine, and what this
branch closes. Method: REA (Reverse Engineer Anything, v6.7.0) capability
probing + evidence collection, our own binary-forensics tooling where REA's
deep-analysis providers are unavailable, and a full contract audit of
`lib/engine/recovery_engine.dart`.

---

## 1. REA evidence collected

### 1.1 REA capability audit (honest limits)

`rea analyze` on the benchmark binary reports all four deep-analysis
providers unavailable, with exact reasons recorded:

| provider | rejection |
|----------|-----------|
| ghidra   | `not_configured` (GHIDRA_INSTALL_DIR) + universal Mach-O must be thinned first |
| hopper   | `executable_missing` (/opt/hopper/bin/Hopper) |
| ida      | `not_configured` (REA_IDA_MCP_CONFIG) |
| kuna     | `not_configured` (REA_KUNA_COMMAND) + no universal Mach-O slice selection |

→ Native decompilation remains blocked (same as the Phase 1 audit). We do
**not** guess: where REA cannot look, we say so and substitute our own
deterministic tooling (`scripts/macho_symbols.py`, symbol-name evidence
only — no code copied).

### 1.2 REA `identify-flutter-build` on OUR release APK (build-5)

Real Evidence bundle produced (`evidence/rea/flutter_build_identification.json`):

- `evidence_id`: `ev_230f795c0f42...`, SHA-256 of the APK recorded
- Dart AOT snapshot hash: `0451907c2eaa8467e848c0067bfe8ed4`
- **Observation raised by REA:** each `libapp.so` "carries 1 snapshot
  section(s); a complete AOT payload carries two"
- **Fact-check (independent ELF parse):** `lib/arm64-v8a/libapp.so` has 11
  standard sections and **no** snapshot-named sections at all — Flutter AOT
  payloads live behind `.rodata` symbols, not named sections. REA's own
  output disclaims partial coverage ("findings are observations of that
  layout"). Verdict: benign heuristic limitation, no action needed.

### 1.3 Benchmark engine architecture (symbol-name evidence)

From the Mach-O symbol table (both slices, ~24k symbols):

| namespace | symbols | meaning for our design |
|-----------|--------:|------------------------|
| `recovery_core` | 110 | their engine is one core crate behind a thin FFI |
| `aho_corasick`  | 387 | multi-pattern signature matching (headers) |
| `memchr`        | 64  | fast byte search (footers) |
| `serde_json`    | 57  | they pass JSON across some boundary |
| async runtimes  | 0 in top namespaces | sync worker threads + polling |

**Validated choices in our implementation:** aho-corasick + memchr +
sync worker threads + poll-based events. **Deliberate divergence:** we use
fixed-layout `repr(C)` structs at the boundary instead of JSON — typed,
allocation-light, no parser in the UI loop.

## 2. Contract gaps closed by this branch

Found during the audit + FFI bring-up (each one is now covered by a test):

| # | Gap | Fix |
|---|-----|-----|
| 1 | No real scanning at all (Phase 1 simulated) | `recovery-core`: 10 signatures, windowed carving, follow-up footer search, size-field extraction (RIFF), duplicate fingerprints (FNV-1a 8 KiB), integrity classification |
| 2 | No real survey / backup | stratified block sampling (zero/data/unreadable/wipe), chunked bit-for-bit backup with self-verifying completion |
| 3 | Engine state raced with the terminal event ("Done observed" ≠ "results readable") | **finalize-at-delivery**: state copied into the engine exactly when the terminal event is polled |
| 4 | `busy` flag ownership race (cleared by worker after Done) | busy is owned by the FFI boundary: set at start, cleared at terminal delivery or session free |
| 5 | Double-free of a session handle (UB → SIGSEGV) | found by review; session free is single-owner, worker keeps its own handles |
| 6 | Signature lookup for verify-on-recover keyed by folder (folder ≠ unique) | `CarvedFile.sig_index` carried from scan to recover |
| 7 | `frf_last_error` returned a stale first message forever | replaced storage; valid until next failure, documented |
| 8 | `source_refresh` wiped explicitly registered images | pinned sources survive refresh; deterministic ordering (env → pinned → block devices) |
| 9 | Dart start failures would throw synchronously inside UI code | Dart `async*` wrappers: failures surface via stream `onError` like the simulated engine |

## 3. Remaining gaps (the "other needed things" — Phase 3 backlog)

1. **Device enumeration beyond Linux** — `/sys/block` + root-disk lock via
   `/proc/cmdline` works on Linux; macOS (`diskutil`/DiskArbitration) and
   Windows (SetupAPI) need platform channels; Android needs Storage Access
   Framework + USB host; iOS cannot access raw devices (App Store policy).
2. **Cross-compiling the engine** — Android (`aarch64-linux-android` +
   JNI loader) and iOS (`aarch64-apple-ios` XCFramework) are not built yet;
   those bundles ship with the simulated engine (FFI off by default).
3. **EXIF capture dates** — `capturedAt` is 0 (unknown); JPEG EXIF parsing
   would enable real `byCaptureDate` grouping.
4. **License verification** — regex check is a placeholder; the benchmark
   uses Ed25519 signed keys (CryptoKit). We should adopt `ed25519-dalek`.
5. **Large-file heuristic** — footers beyond the 32 MiB follow-up cap are
   reported *fragmented* rather than searched forever (documented trade-off;
   a streaming re-scan mode could lift it).
6. **Event throttling** — progress events per 4 MiB window flood big drives;
   add a minimum-interval timer in the worker.
7. **Hardware unreadable sectors** — real IO errors on block devices are
   counted, but retry/reallocation telemetry (SMART) is future work.
8. **REA obligation ledger** — `build-reconstruction-obligation-ledger`
   needs a canonical Evidence bundle as input; wiring our test results into
   that schema is pending.

## 4. Verification summary (this branch)

| gate | result |
|------|--------|
| `cargo test --workspace` (core + C ABI) | **8/8 pass** (incl. byte-identical recover, cancel, survey, ABI pipeline) |
| `flutter analyze` | **0 issues** |
| `flutter test` with the real dylib loaded | **53/53 pass** (49 existing incl. 26 goldens + 4 new FFI tests) |
| golden matrix | unchanged (engine default stays simulated; UI untouched) |
| CI | cargo + dylib build added to the gate; engine bundled into linux/windows/macos artifacts |
