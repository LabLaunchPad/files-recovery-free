//! Survey — quick stratified block sampling: how much is data, how much
//! is unreadable, is the medium wiped.

use std::sync::mpsc::Sender;
use std::thread;

use crate::blocksource::BlockSource;
use crate::scanner::Control;

#[derive(Clone, Debug)]
pub struct SurveyOutcome {
    pub data_percent: f64,
    pub unreadable_percent: f64,
    pub wipe_detected: bool,
    pub sampled_blocks: usize,
}

pub type SurveyResultMsg = Result<SurveyOutcome, (i32, String)>;

/// Samples `samples` blocks at stratified offsets. Sends exactly one
/// message (Ok / Err) on `tx` when finished.
pub fn run_survey<S: BlockSource>(
    source: &mut S,
    samples: usize,
    block: usize,
    control: std::sync::Arc<Control>,
    tx: Sender<SurveyResultMsg>,
) {
    let total = source.total_bytes();
    if total == 0 || samples == 0 {
        let _ = tx.send(Err((crate::error_codes::INVALID_SOURCE, "empty source".into())));
        return;
    }
    let step = (total / samples as u64).max(block as u64);
    let mut buf = vec![0u8; block];
    let (mut data, mut unreadable, mut taken) = (0usize, 0usize, 0usize);

    let mut i = 0usize;
    while i < samples {
        if control.cancelled.load(std::sync::atomic::Ordering::Relaxed) {
            let _ = tx.send(Err((crate::error_codes::CANCELLED, "cancelled".into())));
            return;
        }
        let offset = (i as u64 * step).min(total.saturating_sub(1));
        match source.read_at(offset, &mut buf) {
            Ok(n) if n == block => {
                if buf.iter().all(|&b| b == 0) {
                    // free (wiped/zero) block — tracked implicitly by data==0
                } else {
                    data += 1;
                }
            }
            Ok(_) => data += 1, // short tail block counts as data
            Err(_) => unreadable += 1,
        }
        taken += 1;
        i += 1;
    }

    let data_percent = data as f64 * 100.0 / taken as f64;
    let unreadable_percent = unreadable as f64 * 100.0 / taken as f64;
    let wipe_detected = data == 0 && unreadable == 0 && taken > 0;
    let _ = tx.send(Ok(SurveyOutcome {
        data_percent,
        unreadable_percent,
        wipe_detected,
        sampled_blocks: taken,
    }));
}

/// Convenience: run the survey on a dedicated thread, mirroring scan/backup.
pub fn spawn_survey<S: BlockSource + 'static>(
    mut source: S,
    samples: usize,
    block: usize,
    control: std::sync::Arc<Control>,
) -> std::sync::mpsc::Receiver<SurveyResultMsg> {
    let (tx, rx) = std::sync::mpsc::channel();
    thread::spawn(move || run_survey(&mut source, samples, block, control, tx));
    rx
}
