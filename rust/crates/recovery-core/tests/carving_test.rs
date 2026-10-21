//! End-to-end carving tests against a synthetic disk image.

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

use recovery_core::blocksource::FileSource;
use recovery_core::ops::{run_recover, Receipt};
use recovery_core::scanner::{run_scan, Control, ScanConfig, ScanEvent, ScanOutput};
use recovery_core::survey::run_survey;
use recovery_core::{FileKind, FileState};

/// Deterministic signature-free junk (printable ASCII, no false headers).
fn junk(len: usize) -> Vec<u8> {
    const ALPHA: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789ABCDEF";
    (0..len).map(|i| ALPHA[i * 7 % ALPHA.len()]).collect()
}

struct ImageSpec {
    start: usize,
    len: usize,
    kind: &'static str,
}

/// Builds an image with embedded files; returns specs (positions/sizes).
fn build_image(path: &std::path::Path) -> Vec<ImageSpec> {
    let mut img: Vec<u8> = Vec::new();
    let mut specs = Vec::new();
    img.extend_from_slice(&junk(512 * 1024)); // junk head

    // JPEG #1 — 200 KB (forces the follow-up footer search: > chunk 64 KiB)
    let start = img.len();
    img.extend_from_slice(&[0xFF, 0xD8, 0xFF, 0xE0]);
    img.extend_from_slice(&junk(200 * 1024));
    img.extend_from_slice(&[0xFF, 0xD9]);
    specs.push(ImageSpec { start, len: img.len() - start, kind: "jpeg" });

    // PNG — 8 KB with real footer
    let start = img.len();
    img.extend_from_slice(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
    img.extend_from_slice(&junk(8 * 1024));
    img.extend_from_slice(b"IEND\xAE\xB2\x60\x82");
    specs.push(ImageSpec { start, len: img.len() - start, kind: "png" });

    // PDF — 64 KB with %%EOF
    let start = img.len();
    img.extend_from_slice(b"%PDF-1.4\n");
    img.extend_from_slice(&junk(64 * 1024));
    img.extend_from_slice(b"%%EOF");
    specs.push(ImageSpec { start, len: img.len() - start, kind: "pdf" });

    // ZIP — with EOCD footer
    let start = img.len();
    img.extend_from_slice(b"PK\x03\x04");
    img.extend_from_slice(&junk(16 * 1024));
    img.extend_from_slice(b"PK\x05\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    specs.push(ImageSpec { start, len: img.len() - start, kind: "zip" });

    // RIFF/WAVE — exact size field (16 KiB total, size field = total - 8)
    let start = img.len();
    img.extend_from_slice(b"RIFF");
    img.extend_from_slice(&(16384u32 - 8).to_le_bytes());
    img.extend_from_slice(b"WAVE");
    img.extend_from_slice(&junk(16384 - 12)); // pad to exactly 16384 bytes
    debug_assert_eq!(img.len() - start, 16384);
    specs.push(ImageSpec { start, len: 16384, kind: "riff" });

    // JPEG #2 — byte-identical to JPEG #1 (duplicate detection)
    let start = img.len();
    img.extend_from_slice(&[0xFF, 0xD8, 0xFF, 0xE0]);
    img.extend_from_slice(&junk(200 * 1024));
    img.extend_from_slice(&[0xFF, 0xD9]);
    specs.push(ImageSpec { start, len: img.len() - start, kind: "jpeg-dup" });

    // MP4 — ftyp at offset 4, no verifiable extent -> fragmented
    let start = img.len();
    img.extend_from_slice(&[0x00, 0x00, 0x00, 0x18]);
    img.extend_from_slice(b"ftypisom\x00\x00\x02\x00isomiso2");
    img.extend_from_slice(&junk(24 * 1024));
    specs.push(ImageSpec { start, len: img.len() - start, kind: "mp4" });

    img.extend_from_slice(&junk(256 * 1024)); // junk tail
    fs::write(path, &img).unwrap();
    specs
}

fn drain(rx: &mpsc::Receiver<ScanEvent>) -> (Vec<ScanEvent>, ScanEvent) {
    let mut all = Vec::new();
    loop {
        match rx.recv_timeout(Duration::from_secs(30)) {
            Ok(e) => {
                let terminal =
                    matches!(e, ScanEvent::Done { .. } | ScanEvent::Cancelled | ScanEvent::Error { .. });
                let is_terminal = terminal;
                all.push(e);
                if is_terminal {
                    let last = all.pop().unwrap();
                    return (all, last);
                }
            }
            Err(_) => panic!("scan stalled"),
        }
    }
}

#[test]
fn scan_carves_expected_files_with_correct_integrity() {
    let dir = std::env::temp_dir().join("frf_core_test_scan");
    fs::create_dir_all(&dir).unwrap();
    let img_path = dir.join("case.img");
    let specs = build_image(&img_path);

    let mut source = FileSource::open(&img_path).unwrap();
    let (tx, rx) = mpsc::channel();
    let results = Arc::new(std::sync::Mutex::new(Vec::new()));
    let cfg = ScanConfig { chunk: 64 * 1024, footer_cap: 8 * 1024 * 1024 };
    run_scan(
        &mut source,
        &cfg,
        Control::new(),
        ScanOutput { events: tx, results: results.clone() },
    );

    let (progress, terminal) = drain(&rx);
    assert!(matches!(terminal, ScanEvent::Done { files_found } if files_found >= 7),
        "terminal={terminal:?} carved={:?}", results.lock().unwrap());
    assert!(!progress.is_empty(), "expected progress events");

    let carved = results.lock().unwrap();
    let jpeg: Vec<_> = carved.iter().filter(|f| f.name.ends_with(".jpg")).collect();
    assert_eq!(jpeg.len(), 2, "two jpegs carved, got {carved:?}");
    assert!(jpeg.iter().any(|f| f.state == FileState::Intact));
    assert!(jpeg.iter().any(|f| f.duplicate), "second identical jpeg flagged");

    let png = carved.iter().find(|f| f.name.ends_with(".png")).expect("png");
    assert_eq!(png.state, FileState::Intact);
    assert_eq!(png.size as usize, specs.iter().find(|s| s.kind == "png").unwrap().len);

    let pdf = carved.iter().find(|f| f.name.ends_with(".pdf")).expect("pdf");
    assert_eq!(pdf.state, FileState::Intact);
    assert_eq!(pdf.kind, FileKind::Document);

    assert!(carved.iter().any(|f| f.name.ends_with(".zip")), "zip carved");
    let riff = carved.iter().find(|f| f.name.ends_with(".wav")).expect("riff");
    assert_eq!(riff.state, FileState::Intact, "size-field derived");
    assert_eq!(riff.size, 16384);

    let mp4 = carved.iter().find(|f| f.name.ends_with(".mp4")).expect("mp4");
    assert_eq!(mp4.state, FileState::Fragmented, "mp4 without extent = fragmented");
    assert_eq!(mp4.kind, FileKind::Video);

    // offsets must match the layout
    let j1 = &jpeg[0];
    let spec = specs.iter().find(|s| s.kind == "jpeg").unwrap();
    assert_eq!(j1.offset as usize, spec.start);

    fs::remove_dir_all(&dir).ok();
}

#[test]
fn recover_writes_byte_identical_files_and_verifies() {
    let dir = std::env::temp_dir().join("frf_core_test_recover");
    fs::create_dir_all(&dir).unwrap();
    let img_path = dir.join("case.img");
    build_image(&img_path);

    let mut source = FileSource::open(&img_path).unwrap();
    let (tx, rx) = mpsc::channel();
    let results = Arc::new(std::sync::Mutex::new(Vec::new()));
    run_scan(
        &mut source,
        &ScanConfig { chunk: 64 * 1024, footer_cap: 8 * 1024 * 1024 },
        Control::new(),
        ScanOutput { events: tx, results: results.clone() },
    );
    let (_, terminal) = drain(&rx);
    assert!(matches!(terminal, ScanEvent::Done { .. }));

    // pick the intact jpeg + png
    let carved = results.lock().unwrap();
    let picks: Vec<_> = carved
        .iter()
        .filter(|f| f.state == FileState::Intact && (f.name.ends_with(".jpg") || f.name.ends_with(".png")))
        .take(2)
        .cloned()
        .collect();
    assert_eq!(picks.len(), 2);
    drop(carved);

    let out_dir = dir.join("out");
    let (tx2, rx2) = mpsc::channel();
    let receipts = Arc::new(std::sync::Mutex::new(Vec::new()));
    run_recover(
        &mut source,
        &picks,
        &out_dir,
        true,
        false,
        Control::new(),
        tx2,
        receipts.clone(),
    );
    let (_, terminal) = drain(&rx2);
    assert!(matches!(terminal, ScanEvent::Done { .. }));

    let got: Vec<Receipt> = receipts.lock().unwrap().clone();
    assert_eq!(got.len(), 2);
    for (r, item) in got.iter().zip(&picks) {
        assert!(r.verified, "receipt verified for {}", r.file_name);
        assert!(r.target_path.contains(&item.name));
        // byte-identical check against the source range
        let raw = fs::read(&r.target_path).unwrap();
        let src_range = read_range(&img_path, item.offset, item.size);
        assert_eq!(raw, src_range, "{} bytes differ", r.file_name);
    }
    fs::remove_dir_all(&dir).ok();
}

fn read_range(path: &std::path::Path, offset: u64, len: u64) -> Vec<u8> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = fs::File::open(path).unwrap();
    f.seek(SeekFrom::Start(offset)).unwrap();
    let mut buf = vec![0u8; len as usize];
    f.read_exact(&mut buf).unwrap();
    buf
}

#[test]
fn cancel_stops_the_scan() {
    let dir = std::env::temp_dir().join("frf_core_test_cancel");
    fs::create_dir_all(&dir).unwrap();
    let img_path = dir.join("case.img");
    build_image(&img_path);

    let mut source = FileSource::open(&img_path).unwrap();
    let (tx, rx) = mpsc::channel();
    let control = Control::new();
    let ctrl2 = control.clone();
    let t = std::thread::spawn(move || {
        // cancel as soon as the first progress arrives
        loop {
            match rx.recv_timeout(Duration::from_secs(10)) {
                Ok(ScanEvent::Progress { .. }) => {
                    ctrl2.cancelled.store(true, std::sync::atomic::Ordering::Relaxed);
                }
                Ok(e) => break e,
                Err(_) => panic!("no terminal event"),
            }
        }
    });
    let cfg = ScanConfig { chunk: 64 * 1024, footer_cap: 8 * 1024 * 1024 };
    run_scan(&mut source, &cfg, control, ScanOutput { events: tx, results: Arc::new(std::sync::Mutex::new(Vec::new())) });
    let terminal = t.join().unwrap();
    assert!(matches!(terminal, ScanEvent::Cancelled), "got {terminal:?}");
    fs::remove_dir_all(&dir).ok();
}

#[test]
fn survey_reports_realistic_percentages() {
    let dir = std::env::temp_dir().join("frf_core_test_survey");
    fs::create_dir_all(&dir).unwrap();
    let img_path = dir.join("case.img");
    build_image(&img_path);

    let mut source = FileSource::open(&img_path).unwrap();
    let (tx, rx) = mpsc::channel();
    run_survey(&mut source, 256, 4096, Control::new(), tx);
    let outcome = rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap();
    // image is almost entirely non-zero junk + files -> high data percent
    assert!(outcome.data_percent > 90.0, "data={outcome:?}");
    assert_eq!(outcome.unreadable_percent, 0.0);
    assert!(!outcome.wipe_detected);
    fs::remove_dir_all(&dir).ok();
}

#[test]
fn junk_is_signature_free() {
    // guards the fixture itself: printable junk must not embed signatures
    let j = junk(4 * 1024 * 1024);
    for sig in recovery_core::signatures::SIGNATURES {
        assert!(
            j.windows(sig.header.len()).all(|w| w != sig.header),
            "junk contains header of {}",
            sig.name
        );
    }
    let mut w = std::io::BufWriter::new(Vec::new());
    w.write_all(&j).unwrap();
}
