//! Minimal JPEG EXIF capture-date extraction.
//!
//! Recovery has no filesystem to ask when a photo was taken — the answer
//! has to come out of the carved bytes themselves. This module parses the
//! smallest useful slice of EXIF: the APP1 "Exif" segment, IFD0, the Exif
//! sub-IFD pointer (tag 0x8769), and the ASCII timestamps
//! `DateTimeOriginal` (0x9003, when the shutter fired — preferred) and
//! `DateTime` (0x0132, file-change time — fallback).
//!
//! Deliberately tiny and total: every read is bounds-checked, IFD walks
//! are capped, and ANY malformed input yields `None` — a corrupt header
//! must degrade to "unknown date", never panic a scan.

/// Unix seconds for the capture date encoded in [data] (a JPEG header
/// region, typically the first 256 KiB of the carved file), or `None`.
pub fn jpeg_capture_date(data: &[u8]) -> Option<i64> {
    // Locate the EXIF APP1 payload ("Exif\0\0" then the TIFF header).
    const MARK: &[u8] = b"Exif\0\0";
    if data.len() < MARK.len() + 8 {
        return None;
    }
    // APP1 must be the first metadata segment; search a small prefix only
    // (timestamps never live deep in the file).
    let head_len = data.len().min(64 * 1024);
    let head = &data[..head_len];
    let pos = head.windows(MARK.len()).position(|w| w == MARK)?;

    let tiff = &head[pos + MARK.len()..];
    if tiff.len() < 8 {
        return None;
    }
    let le = match &tiff[0..2] {
        b"II" => true,
        b"MM" => false,
        _ => return None,
    };
    if u16_at(tiff, 2, le) != 0x2A {
        return None;
    }
    let ifd0 = u32_at(tiff, 4, le) as usize;
    if ifd0 >= tiff.len() {
        return None;
    }

    // IFD0 walk: prefer the Exif sub-IFD, keep DateTime as the fallback.
    let (mut exif_off, mut fallback) = (None, None);
    for_each_entry(tiff, ifd0, le, &mut |e| {
        match u16_at(tiff, e, le) {
            0x8769 => {
                if exif_off.is_none() {
                    exif_off = long_value(tiff, e, le);
                }
            }
            0x0132 => {
                if fallback.is_none() {
                    fallback = ascii_value(tiff, e, le).and_then(|s| parse_exif_ts(&s));
                }
            }
            _ => {}
        }
        true
    });

    if let Some(off) = exif_off {
        if let Some(epoch) = exif_datetime(tiff, off as usize, le) {
            return Some(epoch);
        }
    }
    fallback
}

/// Iterates the entries of the IFD at [ifd_off]; [f] returns false to stop.
/// Caps the walk at 512 entries (real IFDs are far smaller).
fn for_each_entry(tiff: &[u8], ifd_off: usize, le: bool, f: &mut impl FnMut(usize) -> bool) {
    if ifd_off + 2 > tiff.len() {
        return;
    }
    let count = u16_at(tiff, ifd_off, le).min(512) as usize;
    for i in 0..count {
        let e = ifd_off + 2 + i * 12;
        if e + 12 > tiff.len() || !f(e) {
            return;
        }
    }
}

/// Exif sub-IFD: DateTimeOriginal (0x9003), falling back to DateTimeDigitized.
fn exif_datetime(tiff: &[u8], ifd_off: usize, le: bool) -> Option<i64> {
    let mut found = None;
    for_each_entry(tiff, ifd_off, le, &mut |e| {
        let tag = u16_at(tiff, e, le);
        if tag != 0x9003 && tag != 0x9004 {
            return true;
        }
        if found.is_some() {
            return true;
        }
        found = ascii_value(tiff, e, le).and_then(|s| parse_exif_ts(&s));
        true
    });
    found
}

/// ASCII tag value at [entry]: inline when ≤ 4 bytes, else an offset.
fn ascii_value(tiff: &[u8], entry: usize, le: bool) -> Option<String> {
    let vtype = u16_at(tiff, entry + 2, le) as u32;
    let vcount = u32_at(tiff, entry + 4, le) as usize;
    if vtype != 2 || vcount == 0 || vcount > 64 {
        return None;
    }
    let bytes = if vcount <= 4 {
        tiff.get(entry + 8..entry + 8 + vcount)?
    } else {
        let off = u32_at(tiff, entry + 8, le) as usize;
        tiff.get(off..off.checked_add(vcount)?)?
    };
    Some(
        String::from_utf8_lossy(bytes)
            .trim_end_matches('\0')
            .to_string(),
    )
}

/// LONG/SINGLE inline value (used for the Exif sub-IFD pointer).
fn long_value(tiff: &[u8], entry: usize, le: bool) -> Option<u32> {
    let vtype = u16_at(tiff, entry + 2, le);
    let vcount = u32_at(tiff, entry + 4, le);
    match (vtype, vcount) {
        (4, 1) => Some(u32_at(tiff, entry + 8, le)),
        (3, 1) => Some(u16_at(tiff, entry + 8, le) as u32),
        _ => None,
    }
}

/// "YYYY:MM:DD HH:MM:SS" → Unix seconds (UTC; EXIF carries no zone and
/// local-time guessing would break determinism).
pub fn parse_exif_ts(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 19
        || b[4] != b':'
        || b[7] != b':'
        || b[10] != b' '
        || b[13] != b':'
        || b[16] != b':'
    {
        return None;
    }
    let num = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, mo, d, h, mi, se) = (
        num(0..4)?,
        num(5..7)?,
        num(8..10)?,
        num(11..13)?,
        num(14..16)?,
        num(17..19)?,
    );
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || se > 60 {
        return None;
    }
    Some(days_from_civil(y, mo, d) * 86_400 + h * 3_600 + mi * 60 + se)
}

/// Howard Hinnant's days_from_civil (proleptic Gregorian), no chrono dep.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn u16_at(b: &[u8], at: usize, le: bool) -> u16 {
    let (a, c) = (b[at] as u16, b[at + 1] as u16);
    if le {
        a | (c << 8)
    } else {
        (a << 8) | c
    }
}

fn u32_at(b: &[u8], at: usize, le: bool) -> u32 {
    if le {
        u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
    } else {
        u32::from_be_bytes(b[at..at + 4].try_into().unwrap())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a TIFF block with one IFD0 entry + Exif sub-IFD containing
    /// DateTimeOriginal. `le` selects little/big endian.
    fn tiff_with_dto(le: bool, dto: &str) -> Vec<u8> {
        let u16v = |v: u16| {
            if le {
                v.to_le_bytes().to_vec()
            } else {
                v.to_be_bytes().to_vec()
            }
        };
        let u32v = |v: u32| {
            if le {
                v.to_le_bytes().to_vec()
            } else {
                v.to_be_bytes().to_vec()
            }
        };
        let mut t = Vec::new();
        t.extend_from_slice(if le { b"II" } else { b"MM" });
        t.extend(u16v(0x2A));
        t.extend(u32v(8)); // IFD0 at 8

        // Exif sub-IFD goes right after IFD0 (8 + 2 + 12 + 4 = 26).
        let exif_off = 26u32;
        // IFD0: 1 entry (0x8769 LONG 1 → exif_off) + next-IFD 0.
        t.extend(u16v(1));
        t.extend(u16v(0x8769));
        t.extend(u16v(4));
        t.extend(u32v(1));
        t.extend(u32v(exif_off));
        t.extend(u32v(0));

        // Exif IFD: 1 entry (0x9003 ASCII 20 → offset to the string).
        let str_off = exif_off as usize + 2 + 12 + 4;
        t.extend(u16v(1));
        t.extend(u16v(0x9003));
        t.extend(u16v(2));
        t.extend(u32v(20));
        t.extend(u32v(str_off as u32));
        t.extend(u32v(0));

        while t.len() < str_off {
            t.push(0);
        }
        let mut ts = dto.as_bytes().to_vec();
        ts.resize(20, 0);
        t.extend(ts);
        t
    }

    fn jpeg(exif: &[u8]) -> Vec<u8> {
        let mut j = vec![0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x00];
        j.extend_from_slice(b"Exif\0\0");
        j.extend_from_slice(exif);
        j.extend_from_slice(&[0xFF, 0xD9]);
        j
    }

    #[test]
    fn reads_datetime_original_both_endians() {
        // 2024-03-05 14:30:00 UTC
        let want = days_from_civil(2024, 3, 5) * 86_400 + 14 * 3600 + 30 * 60;
        for le in [true, false] {
            let data = jpeg(&tiff_with_dto(le, "2024:03:05 14:30:00"));
            assert_eq!(jpeg_capture_date(&data), Some(want), "le={le}");
        }
    }

    #[test]
    fn plain_jpeg_without_exif_is_unknown() {
        assert_eq!(
            jpeg_capture_date(&[0xFF, 0xD8, 0xFF, 0xE0, 0, 2, 0x10, 0x4A]),
            None
        );
        assert_eq!(jpeg_capture_date(&[]), None);
    }

    #[test]
    fn corrupt_tiff_degrades_to_none() {
        let mut data = jpeg(&tiff_with_dto(true, "2024:03:05 14:30:00"));
        data[10] = b'X'; // break the endianness marker
        data[11] = b'X';
        assert_eq!(jpeg_capture_date(&data), None);
    }

    #[test]
    fn out_of_range_timestamps_are_rejected() {
        assert_eq!(parse_exif_ts("2024:13:05 14:30:00"), None);
        assert_eq!(parse_exif_ts("2024:03:32 14:30:00"), None);
        assert_eq!(parse_exif_ts("2024:03:05 25:30:00"), None);
        assert_eq!(parse_exif_ts("short"), None);
        assert!(parse_exif_ts("2024:03:05 14:30:00").is_some());
    }

    #[test]
    fn timestamp_format_must_be_exif_style() {
        // EXIF uses colons in the date part; ISO timestamps are rejected.
        assert_eq!(parse_exif_ts("2024-03-05T14:30:00"), None);
        assert!(parse_exif_ts("2020:01:01 00:00:00").is_some());
    }
}
