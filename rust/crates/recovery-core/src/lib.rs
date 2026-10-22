//! recovery-core — the Phase 2 carving engine.
//!
//! Pure, safe Rust. No drive-specific code here: everything reads through
//! the [`blocksource::BlockSource`] abstraction, so the same engine scans
//! disk images (tests, backups) and real block devices (when the OS
//! permits). Mirrors the proven production pattern: multi-pattern signature
//! matching (aho-corasick) + fast byte search (memchr) + a sync worker
//! thread the UI talks to through events.
//!
//! Enum discriminants intentionally mirror the Dart `FileKind` / `FileState`
//! orders so the FFI layer can pass integers straight through.

pub mod aligned;
pub mod blocksource;
pub mod enumerate;
pub mod ops;
pub mod scanner;
pub mod signatures;
pub mod survey;

pub const ENGINE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Mirrors Dart `FileKind` order: photo, raw, video, document, audio, archive, other.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FileKind {
    Photo = 0,
    Raw = 1,
    Video = 2,
    Document = 3,
    Audio = 4,
    Archive = 5,
    Other = 6,
}

/// Mirrors Dart `FileState` order: intact, damaged, fragmented, unreadable.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FileState {
    Intact = 0,
    Damaged = 1,
    Fragmented = 2,
    Unreadable = 3,
}

/// FFI-facing error codes (see recovery-ffi FrfEvent.error_code).
pub mod error_codes {
    pub const NONE: i32 = 0;
    pub const IO: i32 = 1;
    pub const CANCELLED: i32 = 2;
    pub const INVALID_SOURCE: i32 = 3;
    pub const CONCURRENT: i32 = 4;
    pub const INVALID_ARG: i32 = 5;
}
