//! recovery-ffi — stable C ABI over recovery-core, loaded from Dart via
//! dart:ffi. Mirrors the production shape: one engine singleton, sessions
//! owned by worker threads, the UI polls events (no cross-language
//! callbacks), fixed-layout structs (no JSON at the boundary).
//!
//! Integer enums mirror the Dart enums exactly:
//! kind: 0 sd, 1 usb, 2 external, 3 internal, 4 disk-image
//! file kind / file state: see recovery-core (same indices as Dart).
//! event kind: 0 progress, 1 done, 2 cancelled, 3 error.

#![allow(clippy::missing_safety_doc)]

use std::ffi::{c_char, c_int, CStr, CString};
use std::fs;
use std::os::raw::c_ulonglong;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

use recovery_core::blocksource::{BlockSource, FileSource};
use recovery_core::ops::{run_backup, run_recover, Receipt};
use recovery_core::scanner::{run_scan, CarvedFile, Control, ScanConfig, ScanEvent, ScanOutput};
use recovery_core::survey::spawn_survey;
use recovery_core::ENGINE_VERSION;

// ---------------------------------------------------------------- structs

pub const FRF_EV_PROGRESS: u32 = 0;
pub const FRF_EV_DONE: u32 = 1;
pub const FRF_EV_CANCELLED: u32 = 2;
pub const FRF_EV_ERROR: u32 = 3;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct FrfSourceInfo {
    pub id: [u8; 64],
    pub name: [u8; 128],
    pub total_bytes: c_ulonglong,
    pub kind: u32,
    pub mounted: u32,
    pub is_system: u32,
    pub fs: [u8; 16],
    pub path: [u8; 512],
    pub mount: [u8; 256],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct FrfSurvey {
    pub data_percent: f64,
    pub unreadable_percent: f64,
    pub wipe_detected: u32,
    pub sampled_blocks: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct FrfEvent {
    pub kind: u32,
    pub done_bytes: c_ulonglong,
    pub total_bytes: c_ulonglong,
    pub unreadable_areas: c_ulonglong,
    pub files_found: c_ulonglong,
    pub error_code: i32,
    pub message: [u8; 256],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct FrfFile {
    pub id: [u8; 32],
    pub name: [u8; 128],
    pub folder: [u8; 64],
    pub size_bytes: c_ulonglong,
    pub kind: u32,
    pub state: u32,
    pub captured_at: i64,
    pub duplicate: u32,
    pub confidence: u32,
    pub offset: c_ulonglong,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct FrfReceipt {
    pub file_id: [u8; 32],
    pub file_name: [u8; 128],
    pub verified: u32,
    pub target_path: [u8; 512],
}

// ------------------------------------------------------------ engine state

#[derive(Clone)]
struct Source {
    id: String,
    name: String,
    total: u64,
    kind: u32,
    mounted: bool,
    is_system: bool,
    fs: String,
    path: Option<PathBuf>,
    mount: String,
}

#[derive(Default)]
struct EngineState {
    sources: Vec<Source>,
    /// Explicitly registered images (frf_source_add_image) — survive refresh.
    pinned: Vec<Source>,
    results: Vec<CarvedFile>,
    receipts: Vec<Receipt>,
    busy: bool,
    last_backup: Option<(String, PathBuf)>,
    last_scan_source: Option<(String, PathBuf)>,
}

fn engine() -> &'static Mutex<EngineState> {
    static E: OnceLock<Mutex<EngineState>> = OnceLock::new();
    E.get_or_init(|| Mutex::new(EngineState::default()))
}

fn last_err() -> &'static Mutex<String> {
    static L: OnceLock<Mutex<String>> = OnceLock::new();
    L.get_or_init(|| Mutex::new(String::new()))
}

fn set_err(msg: impl Into<String>) {
    *last_err().lock().unwrap() = msg.into();
}

// ---------------------------------------------------------------- helpers

/// Free bytes on the volume holding `path`, visible to the current
/// (unprivileged) user. Used for the destination free-space check.
/// 0 means "cannot check" — callers degrade to a warning, not a block.
#[no_mangle]
pub unsafe extern "C" fn frf_free_bytes(path: *const c_char) -> c_ulonglong {
    let Some(p) = read_cstr(path) else {
        set_err("null path");
        return 0;
    };
    free_bytes_inner(p).unwrap_or(0)
}

#[cfg(unix)]
fn free_bytes_inner(path: &str) -> Option<u64> {
    let c = CString::new(path).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::statvfs(c.as_ptr(), &mut st) };
    if rc != 0 {
        return None;
    }
    Some(st.f_bavail as u64 * st.f_frsize as u64)
}

#[cfg(target_os = "windows")]
fn free_bytes_inner(path: &str) -> Option<u64> {
    let mut w: Vec<u16> = path.encode_utf16().collect();
    w.push(0);
    let (mut avail, mut total, mut free) = (0u64, 0u64, 0u64);
    let rc = unsafe {
        get_disk_free_space_ex_w(w.as_ptr(), &mut avail, &mut total, &mut free)
    };
    (rc != 0).then_some(avail)
}

#[cfg(target_os = "windows")]
extern "system" {
    #[link_name = "GetDiskFreeSpaceExW"]
    fn get_disk_free_space_ex_w(
        dir: *const u16,
        avail: *mut u64,
        total: *mut u64,
        free: *mut u64,
    ) -> i32;
}

unsafe fn put_str(buf: &mut [u8], s: &str) {
    let b = s.as_bytes();
    let n = b.len().min(buf.len() - 1);
    buf[..n].copy_from_slice(&b[..n]);
    buf[n] = 0;
}

unsafe fn read_cstr<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        None
    } else {
        CStr::from_ptr(p).to_str().ok()
    }
}

// ----------------------------------------------------------- sources

/// (Re)enumerate scannable sources: disk images from the FRF_SOURCE_PATHS
/// env var (colon-separated), pinned (registered) images, and real block
/// devices/volumes from `recovery_core::enumerate` — IOKit on macOS,
/// SetupAPI on Windows, sysfs+mountinfo on Linux. Read-only discovery,
/// never needs elevation. Returns the source count.
fn refresh_sources_inner() -> usize {
    let mut list: Vec<Source> = Vec::new();
    if let Ok(paths) = std::env::var("FRF_SOURCE_PATHS") {
        for (i, p) in paths.split(':').filter(|s| !s.is_empty()).enumerate() {
            if let Ok(md) = fs::metadata(p) {
                list.push(Source {
                    id: format!("img{i}"),
                    name: Path::new(p)
                        .file_name()
                        .map(|s| s.to_string_lossy().to_string())
                        .unwrap_or_else(|| p.to_string()),
                    total: md.len(),
                    kind: 4, // disk image
                    mounted: true,
                    is_system: false,
                    fs: "RAW".into(),
                    path: Some(PathBuf::from(p)),
                    mount: String::new(),
                });
            }
        }
    }

    // Real devices, all desktop OSes (Phase 3). Whole disks AND mounted
    // volumes/partitions are listed; scanning a locked system disk stays
    // refused one layer up (UI) and by OS permissions at open time.
    let block_devs: Vec<Source> = recovery_core::enumerate::enumerate()
        .into_iter()
        .map(|d| Source {
            id: d.id,
            name: d.name,
            total: d.total,
            kind: d.kind,
            mounted: d.mounted,
            is_system: d.is_system,
            fs: d.fs,
            path: Some(PathBuf::from(d.path)),
            mount: d.mount,
        })
        .collect();

    // order: env images -> pinned (registered) images -> block devices
    let n = {
        let mut st = engine().lock().unwrap();
        list.extend(st.pinned.iter().cloned());
        list.extend(block_devs);
        st.sources = list;
        st.sources.len()
    };
    n
}

// ------------------------------------------------------------ sessions

#[derive(Clone, Copy, PartialEq)]
enum SessionKind {
    Scan,
    Backup,
    Recover,
}

pub struct FrfSession {
    rx: Mutex<Receiver<ScanEvent>>,
    control: Arc<Control>,
    finished: AtomicBool,
    kind: SessionKind,
    results: Option<Arc<Mutex<Vec<CarvedFile>>>>,
    receipts: Option<Arc<Mutex<Vec<Receipt>>>>,
    /// Backup finalization info: (source id, dest path, expected size).
    backup: Option<(String, PathBuf, u64)>,
}

pub struct FrfSurveySession {
    rx: Mutex<Receiver<recovery_core::survey::SurveyResultMsg>>,
    control: Arc<Control>,
    done: AtomicBool,
}

fn open_source(source_id: &str) -> Result<(FileSource, Source), ()> {
    let st = engine().lock().unwrap();
    let Some(src) = st.sources.iter().find(|s| s.id == source_id) else {
        set_err(format!("unknown source id: {source_id}"));
        return Err(());
    };
    if st.busy {
        set_err("another operation is still running");
        return Err(());
    }
    let Some(path) = src.path.clone() else {
        set_err("source has no readable path (permission denied at enumeration)");
        return Err(());
    };
    let info = Source {
        id: src.id.clone(),
        name: src.name.clone(),
        total: src.total,
        kind: src.kind,
        mounted: src.mounted,
        is_system: src.is_system,
        fs: src.fs.clone(),
        path: src.path.clone(),
        mount: src.mount.clone(),
    };
    match FileSource::open(&path) {
        Ok(fs) => Ok((fs, info)),
        Err(e) => {
            set_err(format!("cannot open source: {e}"));
            Err(())
        }
    }
}

fn spawn_scan_session(
    mut source: FileSource,
    source_meta: Source,
    source_path: PathBuf,
    mode: ScanMode,
) -> *mut FrfSession {
    let (tx, rx) = mpsc::channel::<ScanEvent>();
    let control = Control::new();
    let results: Arc<Mutex<Vec<CarvedFile>>> = Arc::new(Mutex::new(Vec::new()));
    let receipts: Arc<Mutex<Vec<Receipt>>> = Arc::new(Mutex::new(Vec::new()));
    let ctrl = control.clone();
    let src_id = source_meta.id.clone();

    let (kind, sess_results, sess_receipts, sess_backup) = match &mode {
        ScanMode::Backup(dest) => (
            SessionKind::Backup,
            None,
            None,
            Some((src_id.clone(), dest.clone(), source.total_bytes())),
        ),
        ScanMode::Scan(_) => {
            // record where the scan reads from so recover re-opens the same bytes
            engine().lock().unwrap().last_scan_source =
                Some((src_id.clone(), source_path.clone()));
            (SessionKind::Scan, Some(results.clone()), None, None)
        }
        ScanMode::Recover(..) => (SessionKind::Recover, None, Some(receipts.clone()), None),
    };

    thread::spawn(move || {
        match mode {
            ScanMode::Backup(dest_path) => {
                run_backup(&mut source, &dest_path, ctrl, tx);
            }
            ScanMode::Scan(_use_backup) => {
                let cfg = ScanConfig::default();
                run_scan(
                    &mut source,
                    &cfg,
                    ctrl,
                    ScanOutput {
                        events: tx,
                        results: results.clone(),
                    },
                );
            }
            ScanMode::Recover(items, dest_dir, keep, by_date) => {
                run_recover(&mut source, &items, &dest_dir, keep, by_date, ctrl, tx, receipts);
            }
        }
        // engine state is finalized at terminal-event DELIVERY (see poll),
        // never here — that keeps "Done observed" == "state readable".
    });

    Box::into_raw(Box::new(FrfSession {
        rx: Mutex::new(rx),
        control,
        finished: AtomicBool::new(false),
        kind,
        results: sess_results,
        receipts: sess_receipts,
        backup: sess_backup,
    }))
}

/// Copies a finished session's outputs into the engine state. Runs exactly
/// once, at terminal delivery (or worker death) — never racy for readers.
fn finalize_session(sess: &FrfSession) {
    let mut st = engine().lock().unwrap();
    match sess.kind {
        SessionKind::Scan => {
            if let Some(r) = &sess.results {
                st.results = r.lock().unwrap().clone();
            }
        }
        SessionKind::Recover => {
            if let Some(r) = &sess.receipts {
                st.receipts = r.lock().unwrap().clone();
            }
        }
        SessionKind::Backup => {
            if let Some((src_id, dest, total)) = &sess.backup {
                // self-verifying: record only complete copies
                if let Ok(md) = fs::metadata(dest) {
                    if md.len() == *total {
                        st.last_backup = Some((src_id.clone(), dest.clone()));
                    }
                }
            }
        }
    }
}

enum ScanMode {
    Backup(PathBuf),
    Scan(bool),
    Recover(Vec<CarvedFile>, PathBuf, bool, bool),
}

// ---------------------------------------------------------------- API

/// Engine version string (static, never freed).
#[no_mangle]
pub extern "C" fn frf_version() -> *const c_char {
    static V: OnceLock<CString> = OnceLock::new();
    V.get_or_init(|| CString::new(format!("recovery-ffi {ENGINE_VERSION}")).unwrap())
        .as_ptr()
}

/// Last error message (valid until the next engine call fails).
#[no_mangle]
pub extern "C" fn frf_last_error() -> *const c_char {
    static E: Mutex<Option<CString>> = Mutex::new(None);
    let mut slot = E.lock().unwrap();
    let msg = last_err().lock().unwrap().clone();
    *slot = Some(CString::new(msg).unwrap_or_default());
    slot.as_ref().unwrap().as_ptr()
}

/// Re-enumerate sources. Returns count or -1.
#[no_mangle]
pub extern "C" fn frf_source_refresh() -> c_int {
    refresh_sources_inner() as c_int
}

/// Register one disk image explicitly (drag & drop / tests). Returns index.
#[no_mangle]
pub unsafe extern "C" fn frf_source_add_image(path: *const c_char) -> c_int {
    let Some(p) = read_cstr(path) else {
        set_err("null path");
        return -1;
    };
    let Ok(md) = fs::metadata(p) else {
        set_err(format!("no such file: {p}"));
        return -1;
    };
    let mut st = engine().lock().unwrap();
    let mut src = Source {
        id: String::new(),
        name: Path::new(p)
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| p.to_string()),
        total: md.len(),
        kind: 4,
        mounted: true,
        is_system: false,
        fs: "RAW".into(),
        path: Some(PathBuf::from(p)),
        mount: String::new(),
    };
    // id = img<N> stable per registered image
    src.id = format!("img{}", st.pinned.len());
    st.pinned.push(src.clone());
    let env_count = std::env::var("FRF_SOURCE_PATHS")
        .map(|v| v.split(':').filter(|s| !s.is_empty()).count())
        .unwrap_or(0);
    let idx = env_count + st.pinned.len() - 1;
    st.sources.insert(env_count, src);
    idx as c_int
}

/// Number of known sources.
#[no_mangle]
pub extern "C" fn frf_source_count() -> c_int {
    engine().lock().unwrap().sources.len() as c_int
}

/// Fill `out` with source `index`. Returns 0 on success, -1 on bounds.
#[no_mangle]
pub unsafe extern "C" fn frf_source_get(index: c_int, out: *mut FrfSourceInfo) -> c_int {
    if out.is_null() {
        return -1;
    }
    let st = engine().lock().unwrap();
    let Some(src) = st.sources.get(index.max(0) as usize) else {
        return -1;
    };
    write_bytes_zero(out, 1);
    let out = &mut *out;
    put_str(&mut out.id, &src.id);
    put_str(&mut out.name, &src.name);
    out.total_bytes = src.total;
    out.kind = src.kind;
    out.mounted = src.mounted as u32;
    out.is_system = src.is_system as u32;
    put_str(&mut out.fs, &src.fs);
    put_str(&mut out.path, &src.path.as_ref().map(|p| p.to_string_lossy().to_string()).unwrap_or_default());
    put_str(&mut out.mount, &src.mount);
    0
}

/// Start the block survey. Returns a session handle or NULL.
#[no_mangle]
pub unsafe extern "C" fn frf_survey_start(source_id: *const c_char) -> *mut FrfSurveySession {
    let Some(id) = read_cstr(source_id) else {
        set_err("null source id");
        return std::ptr::null_mut();
    };
    let (source, _meta) = match open_source(id) {
        Ok(x) => x,
        Err(()) => return std::ptr::null_mut(),
    };
    let rx = spawn_survey(source, 4096, 4096, Control::new());
    Box::into_raw(Box::new(FrfSurveySession {
        rx: Mutex::new(rx),
        control: Control::new(),
        done: AtomicBool::new(false),
    }))
}

/// Poll a survey session: 1 = result ready, 0 = pending, -1 = failed.
#[no_mangle]
pub unsafe extern "C" fn frf_survey_poll(s: *mut FrfSurveySession, out: *mut FrfSurvey) -> c_int {
    if s.is_null() || out.is_null() {
        return -1;
    }
    let sess = &mut *s;
    match sess.rx.lock().unwrap().recv_timeout(Duration::from_millis(2)) {
        Ok(Ok(survey)) => {
            write_bytes_zero(out, 1);
            let out = &mut *out;
            out.data_percent = survey.data_percent;
            out.unreadable_percent = survey.unreadable_percent;
            out.wipe_detected = survey.wipe_detected as u32;
            out.sampled_blocks = survey.sampled_blocks as u32;
            sess.done.store(true, Ordering::Relaxed);
            1
        }
        Ok(Err((code, msg))) => {
            set_err(msg);
            sess.done.store(true, Ordering::Relaxed);
            -code
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => 0,
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            sess.done.store(true, Ordering::Relaxed);
            set_err("survey worker died");
            -1
        }
    }
}

/// Free a survey session.
#[no_mangle]
pub unsafe extern "C" fn frf_survey_free(s: *mut FrfSurveySession) {
    if !s.is_null() {
        drop(Box::from_raw(s));
    }
}

/// Start a bit-for-bit backup of `source_id` into `dest_path`.
#[no_mangle]
pub unsafe extern "C" fn frf_backup_start(
    source_id: *const c_char,
    dest_path: *const c_char,
) -> *mut FrfSession {
    let (Some(id), Some(dest)) = (read_cstr(source_id), read_cstr(dest_path)) else {
        set_err("null argument");
        return std::ptr::null_mut();
    };
    let (source, meta) = match open_source(id) {
        Ok(x) => x,
        Err(()) => return std::ptr::null_mut(),
    };
    engine().lock().unwrap().busy = true;
    let backup_path = meta.path.clone().unwrap_or_default();
    spawn_scan_session(source, meta, backup_path, ScanMode::Backup(PathBuf::from(dest)))
}

/// Start the carving scan of `source_id` (optionally against its backup).
#[no_mangle]
pub unsafe extern "C" fn frf_scan_start(
    source_id: *const c_char,
    use_backup: c_int,
) -> *mut FrfSession {
    let Some(id) = read_cstr(source_id) else {
        set_err("null source id");
        return std::ptr::null_mut();
    };
    // resolve source + optional backup path
    let (path, meta) = {
        let st = engine().lock().unwrap();
        let Some(src) = st.sources.iter().find(|s| s.id == id) else {
            set_err(format!("unknown source id: {id}"));
            return std::ptr::null_mut();
        };
        if st.busy {
            set_err("another operation is still running");
            return std::ptr::null_mut();
        }
        let Some(p) = src.path.clone() else {
            set_err("source has no readable path");
            return std::ptr::null_mut();
        };
        let use_backup_path = if use_backup != 0 {
            st.last_backup
                .as_ref()
                .filter(|(sid, bp)| sid == &src.id && bp.exists())
                .map(|(_, bp)| bp.clone())
        } else {
            None
        };
        let meta = Source {
            id: src.id.clone(),
            name: src.name.clone(),
            total: src.total,
            kind: src.kind,
            mounted: src.mounted,
            is_system: src.is_system,
            fs: src.fs.clone(),
            path: Some(use_backup_path.unwrap_or(p)),
            mount: src.mount.clone(),
        };
        (meta.path.clone().unwrap(), meta)
    };
    let Ok(source) = FileSource::open(&path) else {
        set_err(format!("cannot open {}", path.display()));
        return std::ptr::null_mut();
    };
    engine().lock().unwrap().busy = true;
    spawn_scan_session(source, meta, path, ScanMode::Scan(use_backup != 0))
}

/// Recover selected file ids (comma separated) into `dest_dir`.
#[no_mangle]
pub unsafe extern "C" fn frf_recover_start(
    file_ids_csv: *const c_char,
    dest_dir: *const c_char,
    keep_structure: c_int,
    by_capture_date: c_int,
) -> *mut FrfSession {
    let (Some(ids), Some(dest)) = (read_cstr(file_ids_csv), read_cstr(dest_dir)) else {
        set_err("null argument");
        return std::ptr::null_mut();
    };
    let (items, source_path) = {
        let st = engine().lock().unwrap();
        if st.busy {
            set_err("another operation is still running");
            return std::ptr::null_mut();
        }
        let wanted: Vec<&str> = ids.split(',').map(str::trim).filter(|s| !s.is_empty()).collect();
        let items: Vec<CarvedFile> = st
            .results
            .iter()
            .filter(|f| wanted.contains(&f.id.as_str()))
            .cloned()
            .collect();
        if items.is_empty() {
            set_err("no matching files to recover");
            return std::ptr::null_mut();
        }
        let Some((_, path)) = &st.last_scan_source else {
            set_err("no scan source recorded");
            return std::ptr::null_mut();
        };
        (items, path.clone())
    };
    let Ok(source) = FileSource::open(&source_path) else {
        set_err(format!("cannot open {}", source_path.display()));
        return std::ptr::null_mut();
    };
    engine().lock().unwrap().busy = true;
    let scan_path = source_path.clone();
    let meta = Source {
        id: String::new(),
        name: String::new(),
        total: 0,
        kind: 0,
        mounted: true,
        is_system: false,
        fs: String::new(),
        path: Some(source_path),
        mount: String::new(),
    };
    spawn_scan_session(
        source,
        meta,
        scan_path,
        ScanMode::Recover(items, PathBuf::from(dest), keep_structure != 0, by_capture_date != 0),
    )
}

/// Poll a session: 1 = event delivered, 0 = none yet, -1 = no more events.
#[no_mangle]
pub unsafe extern "C" fn frf_session_poll(s: *mut FrfSession, out: *mut FrfEvent) -> c_int {
    if s.is_null() || out.is_null() {
        return -1;
    }
    let sess = &mut *s;
    let ev = match sess.rx.lock().unwrap().try_recv() {
        Ok(ev) => ev,
        Err(TryRecvError::Empty) => return 0,
        Err(TryRecvError::Disconnected) => {
            if !sess.finished.swap(true, Ordering::Relaxed) {
                finalize_session(sess);
                engine().lock().unwrap().busy = false;
            }
            return -1;
        }
    };
    write_bytes_zero(out, 1);
    let out = &mut *out;
    match ev {
        ScanEvent::Progress { done, total, unreadable, files_found } => {
            out.kind = FRF_EV_PROGRESS;
            out.done_bytes = done;
            out.total_bytes = total;
            out.unreadable_areas = unreadable;
            out.files_found = files_found as u64;
        }
        ScanEvent::Done { files_found } => {
            out.kind = FRF_EV_DONE;
            out.files_found = files_found as u64;
            sess.finished.store(true, Ordering::Relaxed);
            finalize_session(sess);
            engine().lock().unwrap().busy = false;
        }
        ScanEvent::Cancelled => {
            out.kind = FRF_EV_CANCELLED;
            sess.finished.store(true, Ordering::Relaxed);
            finalize_session(sess);
            engine().lock().unwrap().busy = false;
        }
        ScanEvent::Error { code, message } => {
            out.kind = FRF_EV_ERROR;
            out.error_code = code;
            put_str(&mut out.message, &message);
            sess.finished.store(true, Ordering::Relaxed);
            finalize_session(sess);
            engine().lock().unwrap().busy = false;
        }
    }
    1
}

#[no_mangle]
pub unsafe extern "C" fn frf_session_pause(s: *mut FrfSession) {
    if !s.is_null() {
        let s = &mut *s;
        s.control.paused.store(true, Ordering::Relaxed);
    }
}

#[no_mangle]
pub unsafe extern "C" fn frf_session_resume(s: *mut FrfSession) {
    if !s.is_null() {
        let s = &mut *s;
        s.control.paused.store(false, Ordering::Relaxed);
    }
}

#[no_mangle]
pub unsafe extern "C" fn frf_session_cancel(s: *mut FrfSession) {
    if !s.is_null() {
        let s = &mut *s;
        s.control.cancelled.store(true, Ordering::Relaxed);
    }
}

#[no_mangle]
pub unsafe extern "C" fn frf_session_is_finished(s: *mut FrfSession) -> c_int {
    if s.is_null() {
        1
    } else {
        let s = &mut *s;
        s.finished.load(Ordering::Relaxed) as c_int
    }
}

#[no_mangle]
pub unsafe extern "C" fn frf_session_free(s: *mut FrfSession) {
    if !s.is_null() {
        let sess = Box::from_raw(s);
        // The operator released the session: the engine slot is free again.
        // A still-running worker keeps its own handles and finishes safely.
        sess.control.cancelled.store(true, Ordering::Relaxed);
        engine().lock().unwrap().busy = false;
        drop(sess);
    }
}

/// Number of carved files from the last completed scan.
#[no_mangle]
pub extern "C" fn frf_browse_count() -> c_int {
    engine().lock().unwrap().results.len() as c_int
}

/// Fill `out` with carved file `index`. 0 ok, -1 bounds.
#[no_mangle]
pub unsafe extern "C" fn frf_browse_get(index: c_int, out: *mut FrfFile) -> c_int {
    if out.is_null() {
        return -1;
    }
    let st = engine().lock().unwrap();
    let Some(f) = st.results.get(index.max(0) as usize) else {
        return -1;
    };
    write_bytes_zero(out, 1);
    let out = &mut *out;
    put_str(&mut out.id, &f.id);
    put_str(&mut out.name, &f.name);
    put_str(&mut out.folder, &f.folder);
    out.size_bytes = f.size;
    out.kind = f.kind as u32;
    out.state = f.state as u32;
    out.captured_at = f.captured_at;
    out.duplicate = f.duplicate as u32;
    out.confidence = f.confidence;
    out.offset = f.offset;
    0
}

/// Receipts from the last completed recovery.
#[no_mangle]
pub extern "C" fn frf_receipt_count() -> c_int {
    engine().lock().unwrap().receipts.len() as c_int
}

#[no_mangle]
pub unsafe extern "C" fn frf_receipt_get(index: c_int, out: *mut FrfReceipt) -> c_int {
    if out.is_null() {
        return -1;
    }
    let st = engine().lock().unwrap();
    let Some(r) = st.receipts.get(index.max(0) as usize) else {
        return -1;
    };
    write_bytes_zero(out, 1);
    let out = &mut *out;
    put_str(&mut out.file_id, &r.file_id);
    put_str(&mut out.file_name, &r.file_name);
    out.verified = r.verified as u32;
    put_str(&mut out.target_path, &r.target_path);
    0
}

unsafe fn write_bytes_zero<T>(p: *mut T, n: usize) {
    std::ptr::write_bytes(p, 0, n);
}
