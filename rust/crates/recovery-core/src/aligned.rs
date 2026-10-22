//! Aligned reads over an arbitrary [`BlockSource`].
//!
//! Raw device nodes (and some mounted volume devices) only serve reads at
//! sector/block boundaries — macOS and Windows reject or misbehave on
//! unaligned offsets/lengths, and Linux silently tolerates them at a
//! performance cost. Recovery workloads inherently produce unaligned reads
//! (carve candidates start at header matches anywhere in the stream), so
//! the engine funnels ALL raw-device IO through this wrapper: it reads
//! whole aligned windows and slices out the requested bytes, with a
//! one-window cache for the dense fingerprint/footer re-reads.
//!
//! The wrapper is pure logic over any [`BlockSource`], so the strictness
//! is unit-tested with a mock that ERRORS on unaligned inner reads — if
//! the wrapper ever leaks an unaligned request, tests go red.

use std::io;

use crate::blocksource::BlockSource;

/// Alignment discipline for raw device nodes. 4096 covers every current
/// logical block size (512/1024/2048/4096) at negligible amortized cost.
pub const RAW_DEVICE_ALIGN: u64 = 4096;

pub struct AlignedSource<S: BlockSource> {
    inner: S,
    align: u64,
    total: u64,
    // one-window cache
    win_start: u64,
    win_len: usize,
    win: Vec<u8>,
}

impl<S: BlockSource> AlignedSource<S> {
    pub fn new(inner: S, align: u64) -> Self {
        assert!(align > 0 && align.is_power_of_two(), "align must be a power of two");
        Self {
            total: inner.total_bytes(),
            inner,
            align,
            win_start: 0,
            win_len: 0,
            win: Vec::new(),
        }
    }

    pub fn into_inner(self) -> S {
        self.inner
    }

    pub fn align(&self) -> u64 {
        self.align
    }
}

impl<S: BlockSource> BlockSource for AlignedSource<S> {
    fn total_bytes(&self) -> u64 {
        self.total
    }

    fn read_at(&mut self, offset: u64, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() || offset >= self.total {
            return Ok(0);
        }
        let want = buf.len().min((self.total - offset) as usize);
        let start = offset - (offset % self.align);
        let end_excl = (offset + want as u64).min(self.total);
        let span = end_excl - start;

        let cache_hit = self.win_start == start && self.win_len as u64 >= span;
        if !cache_hit {
            let chunks = span.div_ceil(self.align);
            let need = (chunks * self.align) as usize;
            if self.win.len() < need {
                self.win.resize(need, 0);
            }
            let mut filled = 0usize;
            for c in 0..chunks {
                let at = start + c * self.align;
                // EOF tail: the device total is a block multiple, so every
                // full chunk is aligned; only the final chunk can be short.
                let chunk_len = (self.align as usize).min((self.total - at) as usize);
                let n = self
                    .inner
                    .read_at(at, &mut self.win[filled..filled + chunk_len])?;
                filled += n;
                if n < chunk_len {
                    break; // short read = unreadable area / EOF: stop cleanly
                }
            }
            self.win_start = start;
            self.win_len = filled;
        }

        let rel = (offset - start) as usize;
        let avail = self.win_len.saturating_sub(rel);
        let n = want.min(avail);
        buf[..n].copy_from_slice(&self.win[rel..rel + n]);
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::ErrorKind;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// Mock that refuses unaligned inner reads — any wrapper regression
    /// surfaces as an Err instead of silently passing.
    struct Strict {
        data: Vec<u8>,
        reads: Arc<AtomicUsize>,
    }
    impl Strict {
        fn new(data: Vec<u8>) -> (Self, Arc<AtomicUsize>) {
            let reads = Arc::new(AtomicUsize::new(0));
            (Self { data, reads: reads.clone() }, reads)
        }
    }
    impl BlockSource for Strict {
        fn total_bytes(&self) -> u64 {
            self.data.len() as u64
        }
        fn read_at(&mut self, offset: u64, buf: &mut [u8]) -> io::Result<usize> {
            self.reads.fetch_add(1, Ordering::SeqCst);
            if offset % 4096 != 0 {
                return Err(io::Error::new(ErrorKind::InvalidInput, "unaligned offset"));
            }
            if offset >= self.data.len() as u64 || buf.is_empty() {
                return Ok(0);
            }
            let n = buf.len().min(self.data.len() - offset as usize);
            buf[..n].copy_from_slice(&self.data[offset as usize..offset as usize + n]);
            Ok(n)
        }
    }

    fn aligned_len_mock(data: Vec<u8>) -> (impl BlockSource, Arc<AtomicUsize>) {
        Strict::new(data)
    }

    #[test]
    fn unaligned_reads_match_plain_buffer() {
        let data: Vec<u8> = (0..9 * 4096u32).map(|i| (i % 251) as u8).collect();
        let (mock, _) = aligned_len_mock(data.clone());
        let mut src = AlignedSource::new(Box::new(mock) as Box<dyn BlockSource>, RAW_DEVICE_ALIGN);

        // Battery: unaligned starts/lengths, block edges, EOF, past-EOF.
        for &(off, len) in &[
            (0u64, 100usize),
            (1, 1),
            (511, 512),
            (4095, 2),
            (4096, 4096),
            (4097, 8190),
            (12_288, 4096),
            (8191, 9000),
            (0, 9 * 4096),           // whole thing
            (9 * 4096 - 7, 100),     // EOF tail
            (9 * 4096, 10),          // past EOF → 0
        ] {
            let mut got = vec![0u8; len];
            let n = src.read_at(off, &mut got).unwrap();
            let want_end = (off as usize + n).min(data.len());
            assert_eq!(&got[..n], &data[off as usize..want_end], "at {off}+{len}");
        }
    }

    #[test]
    fn window_cache_serves_repeat_reads() {
        let data: Vec<u8> = vec![7u8; 3 * 4096];
        let (mock, reads) = aligned_len_mock(data);
        let mut src = AlignedSource::new(Box::new(mock), RAW_DEVICE_ALIGN);

        let mut a = [0u8; 64];
        src.read_at(10, &mut a).unwrap();
        let after_first = reads.load(Ordering::SeqCst);
        assert!(after_first >= 1);
        src.read_at(12, &mut a).unwrap(); // same window → no inner read
        assert_eq!(reads.load(Ordering::SeqCst), after_first);
        src.read_at(5000, &mut a).unwrap(); // next window → new read
        assert!(reads.load(Ordering::SeqCst) > after_first);
    }

    #[test]
    fn short_read_at_eof_is_copied_honestly() {
        let data: Vec<u8> = vec![9u8; 4096 + 100]; // 100 bytes in the last block
        let (mock, _) = aligned_len_mock(data);
        let mut src = AlignedSource::new(Box::new(mock), RAW_DEVICE_ALIGN);

        let mut got = [0u8; 4096]; // asks a full block at the tail
        let n = src.read_at(4096, &mut got).unwrap();
        assert_eq!(n, 100);
        assert_eq!(&got[..100], &vec![9u8; 100][..]);

        let mut past = [0u8; 8];
        assert_eq!(src.read_at(4096 + 100, &mut past).unwrap(), 0);
    }

    #[test]
    fn total_and_metadata_passthrough() {
        let (mock, _) = aligned_len_mock(vec![0u8; 2 * 4096]);
        let src = AlignedSource::new(Box::new(mock), RAW_DEVICE_ALIGN);
        assert_eq!(src.total_bytes(), 2 * 4096);
        assert_eq!(src.align(), 4096);
    }
}
