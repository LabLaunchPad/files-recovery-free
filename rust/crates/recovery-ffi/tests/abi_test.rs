//! C-ABI integration tests: drives the whole engine exactly the way the
//! Dart bindings do (start -> poll -> browse -> recover -> receipts).

use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::c_void;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use recovery_core_ffi::*;

/// The engine is a process-wide singleton with a busy guard — serialize tests.
static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Printable junk without signatures (same recipe as the core fixture).
fn junk(len: usize) -> Vec<u8> {
    const ALPHA: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789ABCDEF";
    (0..len).map(|i| ALPHA[i * 7 % ALPHA.len()]).collect()
}

fn build_image(path: &std::path::Path) {
    let mut img: Vec<u8> = Vec::new();
    img.extend_from_slice(&junk(256 * 1024));
    for _ in 0..3 {
        img.extend_from_slice(&[0xFF, 0xD8, 0xFF, 0xE0]);
        img.extend_from_slice(&junk(48 * 1024));
        img.extend_from_slice(&[0xFF, 0xD9]);
        img.extend_from_slice(&junk(64 * 1024));
    }
    fs::write(path, &img).unwrap();
}

fn temp_dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("frf_ffi_{tag}"));
    fs::create_dir_all(&d).unwrap();
    d
}

/// Busy-wait until the session delivers a terminal event, collecting events.
fn run_to_terminal(
    sess: *mut FrfSession,
) -> (Vec<FrfEvent>, FrfEvent) {
    let mut ev = FrfEvent { kind: 0, done_bytes: 0, total_bytes: 0, unreadable_areas: 0, files_found: 0, error_code: 0, message: [0; 256] };
    let mut all = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let rc = unsafe { frf_session_poll(sess, &mut ev) };
        assert_ne!(rc, -1, "session dead: {}", last_error());
        if rc == 1 {
            let terminal = ev.kind == FRF_EV_DONE || ev.kind == FRF_EV_CANCELLED || ev.kind == FRF_EV_ERROR;
            all.push(ev);
            if terminal {
                return (all[..all.len() - 1].to_vec(), ev);
            }
        }
        assert!(Instant::now() < deadline, "poll timeout; last={:?}", last_error());
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn cbytes(bytes: &[u8]) -> String {
    unsafe { CStr::from_ptr(bytes.as_ptr().cast()).to_string_lossy().to_string() }
}

fn last_error() -> String {
    unsafe { CStr::from_ptr(frf_last_error()).to_string_lossy().to_string() }
}

#[test]
fn full_pipeline_survey_scan_recover_via_c_abi() {
    let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let dir = temp_dir("pipeline");
    let img = dir.join("card.img");
    build_image(&img);

    // version + source registration
    let ver = unsafe { CStr::from_ptr(frf_version()).to_string_lossy().to_string() };
    assert!(ver.contains("recovery-ffi"), "version={ver}");

    let idx = unsafe {
        frf_source_add_image(CString::new(img.to_str().unwrap()).unwrap().as_ptr())
    };
    assert!(idx >= 0, "add_image failed: {}", last_error());

    assert!(unsafe { frf_source_refresh() } >= 1);

    let mut info = FrfSourceInfo {
        id: [0; 64], name: [0; 128], total_bytes: 0, kind: 0, mounted: 0, is_system: 0,
        fs: [0; 16], path: [0; 512],
    };
    assert_eq!(unsafe { frf_source_get(idx, &mut info) }, 0);
    let sid = cbytes(&info.id);
    let name = cbytes(&info.name);
    assert_eq!(name, "card.img");
    assert_eq!(info.kind, 4, "disk image kind");

    // survey
    let ss = unsafe { frf_survey_start(CString::new(sid.clone()).unwrap().as_ptr()) };
    assert!(!ss.is_null(), "survey_start: {}", last_error());
    let mut survey = FrfSurvey { data_percent: 0.0, unreadable_percent: 0.0, wipe_detected: 0, sampled_blocks: 0 };
    let deadline = Instant::now() + Duration::from_secs(30);
    let rc = loop {
        let rc = unsafe { frf_survey_poll(ss, &mut survey) };
        if rc != 0 { break rc; }
        assert!(Instant::now() < deadline, "survey timeout");
        std::thread::sleep(Duration::from_millis(2));
    };
    assert_eq!(rc, 1, "survey result ready");
    assert!(survey.data_percent > 90.0, "data_percent={}", survey.data_percent);
    unsafe { frf_survey_free(ss) };

    // scan
    let sess = unsafe { frf_scan_start(CString::new(sid.clone()).unwrap().as_ptr(), 0) };
    assert!(!sess.is_null(), "scan_start: {}", last_error());
    let (progress, terminal) = run_to_terminal(sess);
    assert_eq!(terminal.kind, FRF_EV_DONE, "scan done");
    assert!(!progress.is_empty(), "progress events flowed");
    unsafe { frf_session_free(sess) };

    let count = unsafe { frf_browse_count() };
    assert_eq!(count, 3, "three jpegs carved");

    let mut ids = Vec::new();
    for i in 0..count {
        let mut f = FrfFile {
            id: [0; 32], name: [0; 128], folder: [0; 64], size_bytes: 0, kind: 0, state: 0,
            captured_at: 0, duplicate: 0, confidence: 0, offset: 0,
        };
        assert_eq!(unsafe { frf_browse_get(i, &mut f) }, 0);
        let id = cbytes(&f.id);
        let nm = cbytes(&f.name);
        assert!(nm.ends_with(".jpg"));
        assert_eq!(f.kind, 0, "photo kind");
        assert_eq!(f.state, 0, "intact");
        ids.push(id);
    }
    // second copy flagged duplicate
    let mut f2 = FrfFile { id: [0; 32], name: [0; 128], folder: [0; 64], size_bytes: 0, kind: 0, state: 0, captured_at: 0, duplicate: 0, confidence: 0, offset: 0 };
    unsafe { frf_browse_get(1, &mut f2) };
    assert_eq!(f2.duplicate, 1, "duplicate flagged on 2nd identical jpeg");


    // recover the first two
    let out = dir.join("out");
    let csv = CString::new(ids[..2].join(",")).unwrap();
    let rs = unsafe {
        frf_recover_start(csv.as_ptr(), CString::new(out.to_str().unwrap()).unwrap().as_ptr(), 1, 0)
    };
    assert!(!rs.is_null(), "recover_start: {}", last_error());
    let (_, terminal) = run_to_terminal(rs);
    assert_eq!(terminal.kind, FRF_EV_DONE);
    unsafe { frf_session_free(rs) };

    // busy guard, made deterministic: pause a scan mid-flight on a big
    // image, then a second start must be rejected while it is parked.
    let big = dir.join("big.img");
    let mut bigbytes: Vec<u8> = Vec::new();
    bigbytes.extend_from_slice(&junk(96 * 1024 * 1024));
    bigbytes.extend_from_slice(&[0xFF, 0xD8, 0xFF, 0xE0]);
    bigbytes.extend_from_slice(&junk(64 * 1024));
    bigbytes.extend_from_slice(&[0xFF, 0xD9]);
    fs::write(&big, &bigbytes).unwrap();
    let bidx = unsafe { frf_source_add_image(CString::new(big.to_str().unwrap()).unwrap().as_ptr()) };
    assert!(bidx >= 0);
    unsafe { frf_source_refresh() };
    let mut binfo = FrfSourceInfo { id: [0; 64], name: [0; 128], total_bytes: 0, kind: 0, mounted: 0, is_system: 0, fs: [0; 16], path: [0; 512] };
    assert_eq!(unsafe { frf_source_get(bidx, &mut binfo) }, 0);
    let bsid = CString::new(cbytes(&binfo.id)).unwrap();

    let guard = unsafe { frf_scan_start(bsid.as_ptr(), 0) };
    assert!(!guard.is_null(), "guard scan start: {}", last_error());
    unsafe { frf_session_pause(guard) };
    std::thread::sleep(Duration::from_millis(100)); // worker parks at a window gate
    if unsafe { frf_session_is_finished(guard) } == 0 {
        let second = unsafe { frf_scan_start(bsid.as_ptr(), 0) };
        assert!(second.is_null(), "busy guard must reject concurrent scan");
    }
    unsafe { frf_session_cancel(guard) };
    let (_, gterm) = run_to_terminal(guard);
    assert_eq!(gterm.kind, FRF_EV_CANCELLED, "guard scan cancelled");
    unsafe { frf_session_free(guard) };

    let rc_count = unsafe { frf_receipt_count() };
    assert_eq!(rc_count, 2);
    for i in 0..rc_count {
        let mut r = FrfReceipt { file_id: [0; 32], file_name: [0; 128], verified: 0, target_path: [0; 512] };
        assert_eq!(unsafe { frf_receipt_get(i, &mut r) }, 0);
        assert_eq!(r.verified, 1, "verified receipt");
        let p = cbytes(&r.target_path);
        let bytes = fs::read(&p).unwrap_or_default();
        assert_eq!(bytes.len(), 48 * 1024 + 6, "exact carved size written ({p})");
        assert_eq!(&bytes[..3], &[0xFF, 0xD8, 0xFF]);
    }
    fs::remove_dir_all(&dir).ok();
}

#[test]
fn cancel_yields_cancelled_event() {
    let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let dir = temp_dir("cancel");
    let img = dir.join("card.img");
    build_image(&img);
    let idx = unsafe { frf_source_add_image(CString::new(img.to_str().unwrap()).unwrap().as_ptr()) };
    assert!(idx >= 0);
    unsafe { frf_source_refresh() };
    let mut info = FrfSourceInfo { id: [0; 64], name: [0; 128], total_bytes: 0, kind: 0, mounted: 0, is_system: 0, fs: [0; 16], path: [0; 512] };
    unsafe { frf_source_get(idx, &mut info) };
    let sid = CString::new(cbytes(&info.id)).unwrap();

    let sess = unsafe { frf_scan_start(sid.as_ptr(), 0) };
    assert!(!sess.is_null(), "cancel-test scan start: {}", last_error());
    unsafe { frf_session_cancel(sess) };
    let (_, terminal) = run_to_terminal(sess);
    assert_eq!(terminal.kind, FRF_EV_CANCELLED, "cancel must surface as CANCELLED");
    unsafe { frf_session_free(sess) };
    fs::remove_dir_all(&dir).ok();
}

#[test]
fn unknown_source_is_rejected_cleanly() {
    let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let s = unsafe { frf_scan_start(CString::new("nope").unwrap().as_ptr(), 0) };
    assert!(s.is_null());
    assert!(last_error().contains("unknown source"));
}

#[allow(dead_code)]
fn silence(c: *const c_void) {
    let _ = c;
}
