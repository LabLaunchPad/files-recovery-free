//! Block source abstraction — the ONLY way the engine touches storage.

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;

/// Anything the engine can scan: a disk image file, a backup copy, or a
/// real block device (`/dev/sdb` etc.) when opened read-only.
pub trait BlockSource: Send {
    fn total_bytes(&self) -> u64;
    /// Reads up to `buf.len()` bytes at `offset`. Returns bytes read
    /// (short read = unreadable/EOF area). `Err` on hard IO failure.
    fn read_at(&mut self, offset: u64, buf: &mut [u8]) -> io::Result<usize>;
}

/// File-backed source: disk images, `.dd`/`.raw` dumps, backup copies and
/// (on Unix) block device nodes.
pub struct FileSource {
    file: File,
    len: u64,
}

impl FileSource {
    pub fn open(path: &Path) -> io::Result<Self> {
        let file = File::open(path)?;
        let len = file.metadata()?.len();
        Ok(Self { file, len })
    }
}

impl BlockSource for FileSource {
    fn total_bytes(&self) -> u64 {
        self.len
    }

    fn read_at(&mut self, offset: u64, buf: &mut [u8]) -> io::Result<usize> {
        if offset >= self.len || buf.is_empty() {
            return Ok(0);
        }
        self.file.seek(SeekFrom::Start(offset))?;
        let want = (buf.len() as u64).min(self.len - offset) as usize;
        let mut filled = 0usize;
        while filled < want {
            match self.file.read(&mut buf[filled..want]) {
                Ok(0) => break,
                Ok(n) => filled += n,
                Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        Ok(filled)
    }
}
