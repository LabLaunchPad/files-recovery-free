//! Multi-pattern carving scanner.
//!
//! Pipeline per window: read a chunk → aho-corasick finds all signature
//! headers → for each candidate (in order): derive size from a size field,
//! or find the footer via memchr (window first, then a bounded follow-up
//! read ahead), → classify integrity → jump past the carved file.
//! Duplicates are detected by a 64-bit FNV-1a fingerprint of the first
//! 8 KiB + size. All events go through one channel; cancel/pause are
//! atomics checked between chunks.

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use aho_corasick::AhoCorasick;
use memchr::memchr;

use crate::blocksource::BlockSource;
use crate::signatures::SIGNATURES;
use crate::{FileKind, FileState};

/// Shared cancel/pause flags.
pub struct Control {
    pub paused: AtomicBool,
    pub cancelled: AtomicBool,
}

impl Control {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            paused: AtomicBool::new(false),
            cancelled: AtomicBool::new(false),
        })
    }

    pub fn wait_while_paused(&self) {
        while self.paused.load(Ordering::Relaxed) && !self.cancelled.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(10));
        }
    }

    pub fn cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Relaxed)
    }
}

/// Events the scan stream delivers (order: 0..n progress, exactly one terminal).
#[derive(Clone, Debug)]
pub enum ScanEvent {
    Progress {
        done: u64,
        total: u64,
        unreadable: u64,
        files_found: usize,
    },
    Done {
        files_found: usize,
    },
    Cancelled,
    Error {
        code: i32,
        message: String,
    },
}

/// One carved-file record (integer fields mirror the Dart enums).
#[derive(Clone, Debug)]
pub struct CarvedFile {
    pub id: String,
    pub name: String,
    pub folder: String,
    pub size: u64,
    pub kind: FileKind,
    pub state: FileState,
    pub captured_at: i64,
    pub duplicate: bool,
    pub confidence: u32,
    /// Absolute byte offset of the file start inside the source.
    pub offset: u64,
    /// Index into SIGNATURES (used for verify-on-recover).
    pub sig_index: usize,
}

/// Where the scan publishes events and accumulates results.
pub struct ScanOutput {
    pub events: Sender<ScanEvent>,
    pub results: Arc<Mutex<Vec<CarvedFile>>>,
}

#[derive(Clone)]
pub struct ScanConfig {
    /// Window size in bytes (default 4 MiB).
    pub chunk: usize,
    /// Follow-up footer search cap in bytes (default 32 MiB).
    pub footer_cap: u64,
}

impl Default for ScanConfig {
    fn default() -> Self {
        Self {
            chunk: 4 * 1024 * 1024,
            footer_cap: 32 * 1024 * 1024,
        }
    }
}

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

fn fnv1a(data: &[u8]) -> u64 {
    let mut h = FNV_OFFSET;
    for &b in data {
        h ^= b as u64;
        h = h.wrapping_mul(FNV_PRIME);
    }
    h
}

fn find_footer_in(hay: &[u8], footer: &[u8]) -> Option<usize> {
    if footer.len() > hay.len() {
        return None;
    }
    let mut from = 0usize;
    while let Some(p) = memchr(footer[0], &hay[from..]) {
        let at = from + p;
        if at + footer.len() <= hay.len() && &hay[at..at + footer.len()] == footer {
            return Some(at);
        }
        from = at + 1;
    }
    None
}

/// Bounded follow-up footer search that keeps reading the source ahead of
/// the current window. Returns absolute end offset of the footer, or None.
fn find_footer_ahead<S: BlockSource>(
    source: &mut S,
    from: u64,
    cap: u64,
    footer: &[u8],
    control: &Control,
    scratch: &mut [u8],
) -> Option<(u64, bool)> {
    let total = source.total_bytes();
    let mut pos = from;
    let step = scratch.len();
    let mut carry: Vec<u8> = Vec::new();
    let mut io_error = false;
    while pos < total && (pos - from) < cap {
        if control.cancelled() {
            return None;
        }
        let want = ((total - pos) as usize).min(step);
        let got = match source.read_at(pos, &mut scratch[..want]) {
            Ok(g) => g,
            Err(_) => {
                io_error = true;
                break;
            }
        };
        if got == 0 {
            break;
        }
        // Overlap the previous tail with the current buffer so footers
        // crossing a read boundary are still found.
        let mut hay = Vec::with_capacity(carry.len() + got);
        hay.extend_from_slice(&carry);
        hay.extend_from_slice(&scratch[..got]);
        if let Some(rel) = find_footer_in(&hay, footer) {
            let abs_end = pos + carry.len() as u64 + rel as u64 + footer.len() as u64;
            return Some((abs_end, io_error));
        }
        let keep = footer.len().saturating_sub(1).min(got);
        carry = scratch[got - keep..got].to_vec();
        pos += got as u64;
    }
    if io_error {
        Some((u64::MAX, true))
    } else {
        None
    }
}

/// Runs the whole scan synchronously on `source`. Designed to be called
/// from a worker thread; the UI observes via `out.events` and can flip
/// `control` at any time.
pub fn run_scan<S: BlockSource>(
    source: &mut S,
    cfg: &ScanConfig,
    control: Arc<Control>,
    out: ScanOutput,
) {
    let total = source.total_bytes();
    let send = |e: ScanEvent| {
        let _ = out.events.send(e);
    };

    let Ok(ac) = AhoCorasick::new(SIGNATURES.iter().map(|s| s.header)) else {
        send(ScanEvent::Error { code: crate::error_codes::IO, message: "signature automaton init failed".into() });
        return;
    };

    let mut results = Vec::new();
    let mut seen: HashSet<(u64, u64)> = HashSet::new();
    let mut unreadable: u64 = 0;
    let mut offset: u64 = 0;
    let mut counter: u64 = 0;
    let mut window = vec![0u8; cfg.chunk];
    let mut ahead_scratch = vec![0u8; 1024 * 1024];

    while offset < total {
        control.wait_while_paused();
        if control.cancelled() {
            send(ScanEvent::Cancelled);
            return;
        }
        let want = ((total - offset) as usize).min(cfg.chunk);
        let got = match source.read_at(offset, &mut window[..want]) {
            Ok(g) => g,
            Err(_) => {
                unreadable += 1;
                offset += want as u64;
                send(ScanEvent::Progress {
                    done: offset.min(total),
                    total,
                    unreadable,
                    files_found: results.len(),
                });
                continue;
            }
        };
        if got == 0 {
            break;
        }
        let short = got < want;
        let data = &window[..got];

        let mut matches: Vec<(usize, usize)> = ac
            .find_iter(data)
            .map(|m| (m.start(), m.pattern().as_u32() as usize))
            .collect();
        matches.sort_unstable();

        let mut consumed_to = 0usize; // position in `data` already claimed by a carved file
        for (pos, pat_idx) in matches {
            if control.cancelled() {
                send(ScanEvent::Cancelled);
                return;
            }
            if pos < consumed_to {
                continue;
            }
            let sig = &SIGNATURES[pat_idx];
            let hdr_off = sig.header_offset as usize;
            if pos < hdr_off {
                continue;
            }
            let start_abs = offset + (pos - hdr_off) as u64;
            if start_abs >= total {
                continue;
            }

            // ---- size determination ------------------------------------
            let mut size: u64 = 0;
            let mut io_error = false;

            if let Some(sf) = sig.size_field {
                let at = pos + sf.rel_offset as usize;
                if at + 4 <= got {
                    let v = u32::from_le_bytes(data[at..at + 4].try_into().unwrap()) as u64;
                    let candidate = v.saturating_add(sf.add);
                    if candidate >= sig.min_size
                        && candidate <= sig.max_size
                        && start_abs + candidate <= total
                    {
                        size = candidate;
                    }
                }
            }

            if size == 0 {
                if let Some(footer) = sig.footer {
                    // 1) footer inside the current window?
                    let search_from = pos + footer.len(); // no footer before header ends
                    if search_from < got {
                        if let Some(rel) = find_footer_in(&data[search_from..], footer) {
                            size = (search_from + rel + footer.len()) as u64 - (pos - hdr_off) as u64;
                        }
                    }
                    // 2) bounded follow-up read ahead of the window
                    if size == 0 {
                        let ahead_from = offset + got as u64;
                        let cap = sig.footer_search_cap.min(cfg.footer_cap);
                        if sig.footer_search_cap > 0 && ahead_from < total {
                            match find_footer_ahead(
                                source,
                                ahead_from,
                                cap,
                                footer,
                                &control,
                                &mut ahead_scratch,
                            ) {
                                Some((end, _err)) => {
                                    if end != u64::MAX {
                                        size = end - start_abs;
                                    } else {
                                        io_error = true;
                                    }
                                }
                                None => {
                                    if control.cancelled() {
                                        send(ScanEvent::Cancelled);
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            let (state, confidence, size) = if size >= sig.min_size && size <= sig.max_size {
                if io_error {
                    (FileState::Damaged, 45, size)
                } else if sig.footer.is_some() || sig.size_field.is_some() {
                    (FileState::Intact, 93, size)
                } else {
                    (FileState::Fragmented, 62, size.min(sig.max_size))
                }
            } else {
                // No verifiable extent → fragmented heuristic slice.
                let heuristic = sig
                    .max_size
                    .min(cfg.footer_cap.max(1024 * 1024))
                    .min(total - start_abs);
                if heuristic < sig.min_size {
                    continue;
                }
                (FileState::Fragmented, 55, heuristic)
            };

            // ---- duplicate fingerprint (first 8 KiB) --------------------
            let mut fp_buf = [0u8; 8 * 1024];
            let fp_len = ((size as usize).min(fp_buf.len())).min(
                ((total - start_abs) as usize).min(fp_buf.len()),
            );
            let fp = if fp_len > 0 {
                match source.read_at(start_abs, &mut fp_buf[..fp_len]) {
                    Ok(n) => (fnv1a(&fp_buf[..n]), size),
                    Err(_) => (0, size),
                }
            } else {
                (0, size)
            };
            let duplicate = !seen.insert(fp);
            let _ = fp;

            counter += 1;
            results.push(CarvedFile {
                id: format!("f{:x}", start_abs),
                name: format!(
                    "{}_{:04}.{}",
                    sig.name.to_lowercase(),
                    counter % 10000,
                    sig.ext
                ),
                folder: sig.folder.to_string(),
                size,
                kind: sig.kind,
                state,
                captured_at: 0,
                duplicate,
                confidence,
                offset: start_abs,
                sig_index: pat_idx,
            });
            consumed_to = (pos - hdr_off) + size.min(got as u64 - (pos - hdr_off) as u64) as usize;
        }

        if short {
            unreadable += 1;
        }
        offset += got as u64;
        send(ScanEvent::Progress {
            done: offset.min(total),
            total,
            unreadable,
            files_found: results.len(),
        });
    }

    {
        let mut sink = out.results.lock().unwrap();
        sink.extend(results.iter().cloned());
    }
    send(ScanEvent::Done {
        files_found: results.len(),
    });
}
