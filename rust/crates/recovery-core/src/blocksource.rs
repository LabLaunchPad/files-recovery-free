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

/// Lets a boxed source (concrete or `dyn`) flow through the generic
/// `run_*` pipelines unchanged.
impl<T: BlockSource + ?Sized> BlockSource for Box<T> {
    fn total_bytes(&self) -> u64 {
        (**self).total_bytes()
    }
    fn read_at(&mut self, offset: u64, buf: &mut [u8]) -> io::Result<usize> {
        (**self).read_at(offset, buf)
    }
}

/// True when [path] names a raw device node the OS may refuse to serve
/// with unaligned IO: `/dev/*` on Unix, `\\.\...` on Windows. Pure string
/// logic (testable on every host); the FFI layer wraps such sources in
/// [`crate::aligned::AlignedSource`].
pub fn is_raw_device_path(path: &Path) -> bool {
    let s = path.to_string_lossy();
    s.starts_with("/dev/") || s.starts_with(r"\\.\")
}

/// File-backed source: disk images, `.dd`/`.raw` dumps, backup copies and
/// (on Unix) block device nodes.
///
/// Device nodes report `st_size == 0` from plain metadata, so the true
/// capacity is asked from the OS (BLKGETSIZE64 / DKIOCGETBLOCKCOUNT /
/// IOCTL_DISK_GET_LENGTH_INFO). Images keep their filesystem size.
pub struct FileSource {
    file: File,
    len: u64,
    raw: bool,
}

#[cfg(unix)]
fn unix_device_len(file: &File) -> Option<u64> {
    use std::os::fd::AsRawFd;
    let fd = file.as_raw_fd();
    #[cfg(target_os = "linux")]
    {
        let mut n: u64 = 0;
        // BLKGETSIZE64 = 0x80081272 — u64 byte count of the whole device
        // (stable across x86_64/aarch64/armv7/riscv Linux ABIs).
        const BLKGETSIZE64: libc::c_ulong = 0x8008_1272;
        let rc = unsafe { libc::ioctl(fd, BLKGETSIZE64, &mut n) };
        return (rc == 0).then_some(n);
    }
    #[cfg(target_os = "macos")]
    {
        // DKIOCGETBLOCKCOUNT (u64) × DKIOCGETBLOCKSIZE (u32).
        const DKIOCGETBLOCKCOUNT: libc::c_ulong = 0x4008_6419;
        const DKIOCGETBLOCKSIZE: libc::c_ulong = 0x4004_6418;
        let mut blocks: u64 = 0;
        let mut bsize: u32 = 0;
        let rc1 = unsafe { libc::ioctl(fd, DKIOCGETBLOCKCOUNT, &mut blocks) };
        let rc2 = unsafe { libc::ioctl(fd, DKIOCGETBLOCKSIZE, &mut bsize) };
        return (rc1 == 0 && rc2 == 0 && bsize > 0).then_some(blocks * bsize as u64);
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        let _ = fd;
        None
    }
}

#[cfg(windows)]
fn windows_device_len(path: &Path) -> Option<u64> {
    use std::os::windows::ffi::OsStrExt;
    const IOCTL_DISK_GET_LENGTH_INFO: u32 = 0x0007_405C;
    #[repr(C)]
    #[derive(Default)]
    struct GetLengthInformation {
        length: i64,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn CreateFileW(
            filename: *const u16,
            access: u32,
            share: u32,
            sa: *mut core::ffi::c_void,
            disposition: u32,
            flags: u32,
            template: *mut core::ffi::c_void,
        ) -> *mut core::ffi::c_void;
        fn DeviceIoControl(
            handle: *mut core::ffi::c_void,
            code: u32,
            in_buf: *mut core::ffi::c_void,
            in_len: u32,
            out_buf: *mut core::ffi::c_void,
            out_len: u32,
            ret_len: *mut u32,
            overlapped: *mut core::ffi::c_void,
        ) -> i32;
        fn CloseHandle(handle: *mut core::ffi::c_void) -> i32;
    }
    const GENERIC_READ: u32 = 0x8000_0000;
    const FILE_SHARE_READ: u32 = 1;
    const FILE_SHARE_WRITE: u32 = 2;
    const OPEN_EXISTING: u32 = 3;

    let wide: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let handle = unsafe {
        CreateFileW(
            wide.as_ptr(),
            GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            std::ptr::null_mut(),
            OPEN_EXISTING,
            0,
            std::ptr::null_mut(),
        )
    };
    if handle as isize == -1 || handle.is_null() {
        return None;
    }
    let mut out = GetLengthInformation::default();
    let mut ret: u32 = 0;
    let ok = unsafe {
        DeviceIoControl(
            handle,
            IOCTL_DISK_GET_LENGTH_INFO,
            std::ptr::null_mut(),
            0,
            &mut out as *mut _ as *mut core::ffi::c_void,
            std::mem::size_of::<GetLengthInformation>() as u32,
            &mut ret,
            std::ptr::null_mut(),
        )
    };
    unsafe { CloseHandle(handle) };
    (ok != 0 && out.length > 0).then_some(out.length as u64)
}

impl FileSource {
    pub fn open(path: &Path) -> io::Result<Self> {
        let file = File::open(path)?;
        let md = file.metadata()?;
        let mut len = md.len();
        let mut raw = false;

        #[cfg(unix)]
        {
            use std::os::unix::fs::FileTypeExt;
            if md.file_type().is_block_device() {
                raw = true;
                if let Some(n) = unix_device_len(&file) {
                    len = n;
                }
            }
        }
        #[cfg(windows)]
        {
            if is_raw_device_path(path) {
                raw = true;
                if let Some(n) = windows_device_len(path) {
                    len = n;
                }
            }
        }

        Ok(Self { file, len, raw })
    }

    /// True when this source is a raw device node (alignment discipline
    /// required, capacity came from an OS device query).
    pub fn is_raw(&self) -> bool {
        self.raw
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_path_detection() {
        assert!(is_raw_device_path(Path::new("/dev/sdb")));
        assert!(is_raw_device_path(Path::new("/dev/disk4s1")));
        assert!(is_raw_device_path(Path::new(r"\\.\PhysicalDrive1")));
        assert!(!is_raw_device_path(Path::new("/tmp/card.img")));
        assert!(!is_raw_device_path(Path::new("C:\\data\\card.img")));
        assert!(!is_raw_device_path(Path::new("relative.img")));
    }

    #[test]
    fn image_file_reports_file_size() {
        let dir = std::env::temp_dir().join("frf_blocksource_img");
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("img.bin");
        std::fs::write(&p, vec![0xABu8; 7777]).unwrap();
        let src = FileSource::open(&p).unwrap();
        assert_eq!(src.total_bytes(), 7777);
        assert!(!src.is_raw());
    }
}
