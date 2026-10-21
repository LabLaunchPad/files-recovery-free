//! Backup (bit-for-bit safety copy) and recover (write carved files out).

use std::fs::File;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

use crate::blocksource::BlockSource;
use crate::scanner::{CarvedFile, Control, ScanEvent};
use crate::signatures::SIGNATURES;

pub const CHUNK: usize = 4 * 1024 * 1024;

/// Verifies a written file: length matches and the signature header matches.
pub fn verify_written(path: &Path, expected_size: u64, sig_index: usize) -> bool {
    let mut f = match File::open(path) {
        Ok(f) => f,
        Err(_) => return false,
    };
    if f.metadata().map(|m| m.len() != expected_size).unwrap_or(true) {
        return false;
    }
    let hdr_len = SIGNATURES[sig_index].header.len();
    let mut head = vec![0u8; hdr_len];
    match f.read_exact(&mut head) {
        Ok(()) => head == SIGNATURES[sig_index].header,
        Err(_) => false,
    }
}

/// Copies the whole source byte-for-byte to `dest`. Never writes to the
/// source. Ends with Done / Cancelled / Error on `tx`.
pub fn run_backup<S: BlockSource>(
    source: &mut S,
    dest: &Path,
    control: Arc<Control>,
    tx: Sender<ScanEvent>,
) {
    let total = source.total_bytes();
    let send = |e: ScanEvent| {
        let _ = tx.send(e);
    };
    let mut out = match File::create(dest) {
        Ok(f) => f,
        Err(e) => {
            send(ScanEvent::Error {
                code: crate::error_codes::IO,
                message: format!("cannot create backup: {e}"),
            });
            return;
        }
    };
    let mut buf = vec![0u8; CHUNK];
    let mut done: u64 = 0;
    while done < total {
        if control.cancelled() {
            send(ScanEvent::Cancelled);
            return;
        }
        while control.paused.load(std::sync::atomic::Ordering::Relaxed)
            && !control.cancelled()
        {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let want = ((total - done) as usize).min(CHUNK);
        match source.read_at(done, &mut buf[..want]) {
            Ok(n) if n > 0 => {
                if let Err(e) = out.write_all(&buf[..n]) {
                    send(ScanEvent::Error {
                        code: crate::error_codes::IO,
                        message: format!("backup write failed: {e}"),
                    });
                    return;
                }
                done += n as u64;
                send(ScanEvent::Progress {
                    done,
                    total,
                    unreadable: 0,
                    files_found: 0,
                });
            }
            Ok(_) => break,
            Err(e) => {
                send(ScanEvent::Error {
                    code: crate::error_codes::IO,
                    message: format!("backup read failed: {e}"),
                });
                return;
            }
        }
    }
    if let Err(e) = out.flush() {
        send(ScanEvent::Error {
            code: crate::error_codes::IO,
            message: format!("backup flush failed: {e}"),
        });
        return;
    }
    send(ScanEvent::Done { files_found: 0 });
}

#[derive(Clone, Debug)]
pub struct Receipt {
    pub file_id: String,
    pub file_name: String,
    pub verified: bool,
    pub target_path: String,
}

/// Writes selected carved ranges out. `keep_structure` mirrors folders;
/// `by_date` groups by capture year when known (Phase 2: mostly unknown).
pub fn run_recover<S: BlockSource>(
    source: &mut S,
    items: &[CarvedFile],
    dest_dir: &Path,
    keep_structure: bool,
    _by_date: bool,
    control: Arc<Control>,
    tx: Sender<ScanEvent>,
    receipts: Arc<Mutex<Vec<Receipt>>>,
) {
    let total: u64 = items.iter().map(|f| f.size).sum::<u64>().max(1);
    let send = |e: ScanEvent| {
        let _ = tx.send(e);
    };
    let mut done: u64 = 0;
    let mut written: Vec<Receipt> = Vec::new();
    let mut buf = vec![0u8; CHUNK];

    for item in items {
        if control.cancelled() {
            send(ScanEvent::Cancelled);
            return;
        }
        let mut rel = PathBuf::new();
        if keep_structure {
            rel.push(&item.folder);
        }
        rel.push(&item.name);
        let target = dest_dir.join(&rel);
        if let Some(parent) = target.parent() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                send(ScanEvent::Error {
                    code: crate::error_codes::IO,
                    message: format!("cannot create folder: {e}"),
                });
                return;
            }
        }
        let out = File::create(&target);
        let mut out = match out {
            Ok(f) => f,
            Err(e) => {
                send(ScanEvent::Error {
                    code: crate::error_codes::IO,
                    message: format!("cannot write {}: {e}", item.name),
                });
                return;
            }
        };

        let mut remaining = item.size;
        let mut offset = item.offset;
        let mut io_error = false;
        while remaining > 0 {
            if control.cancelled() {
                send(ScanEvent::Cancelled);
                return;
            }
            let want = ((remaining as usize).min(CHUNK)).min(buf.len());
            match source.read_at(offset, &mut buf[..want]) {
                Ok(n) if n > 0 => {
                    if out.write_all(&buf[..n]).is_err() {
                        io_error = true;
                        break;
                    }
                    offset += n as u64;
                    remaining -= n as u64;
                    done += n as u64;
                    send(ScanEvent::Progress {
                        done,
                        total,
                        unreadable: 0,
                        files_found: 0,
                    });
                }
                Ok(_) => {
                    io_error = true;
                    break;
                }
                Err(_) => {
                    io_error = true;
                    break;
                }
            }
        }
        let _ = out.flush();
        let verified =
            !io_error && verify_written(&target, item.size, item.sig_index);
        written.push(Receipt {
            file_id: item.id.clone(),
            file_name: item.name.clone(),
            verified,
            target_path: target.to_string_lossy().to_string(),
        });
    }

    {
        let mut sink = receipts.lock().unwrap();
        sink.extend(written);
    }
    send(ScanEvent::Done { files_found: 0 });
}

pub fn io_err(e: io::Error) -> ScanEvent {
    ScanEvent::Error {
        code: crate::error_codes::IO,
        message: e.to_string(),
    }
}
