//! File signature table. Header matching is delegated to aho-corasick;
//! footer location to memchr; size extraction to optional size fields.

use crate::FileKind;

/// How to derive an exact file size from bytes near the header.
#[derive(Clone, Copy)]
pub struct SizeField {
    /// Byte offset (relative to the header start) of a u32 LE length field.
    pub rel_offset: u64,
    /// Added to the field value to obtain the total file size.
    pub add: u64,
}

pub struct Signature {
    pub name: &'static str,
    /// Byte pattern aho-corasick matches anywhere in the stream.
    pub header: &'static [u8],
    /// Real file start is `header_offset` bytes BEFORE the match position
    /// (e.g. MP4: the box length precedes the `ftyp` tag).
    pub header_offset: u64,
    pub footer: Option<&'static [u8]>,
    pub size_field: Option<SizeField>,
    pub min_size: u64,
    pub max_size: u64,
    /// Cap on the follow-up footer search (files bigger than this are
    /// reported fragmented rather than searched forever).
    pub footer_search_cap: u64,
    pub kind: FileKind,
    pub ext: &'static str,
    pub folder: &'static str,
}

macro_rules! sig {
    (
        $name:literal, $header:expr, $off:expr, $footer:expr, $size_field:expr,
        $min:expr, $max:expr, $cap:expr, $kind:expr, $ext:literal, $folder:literal
    ) => {
        Signature {
            name: $name,
            header: $header,
            header_offset: $off,
            footer: $footer,
            size_field: $size_field,
            min_size: $min,
            max_size: $max,
            footer_search_cap: $cap,
            kind: $kind,
            ext: $ext,
            folder: $folder,
        }
    };
}

pub const SIGNATURES: &[Signature] = &[
    sig!("JPEG", b"\xFF\xD8\xFF", 0, Some(b"\xFF\xD9"), None,
         512, 64 * 1024 * 1024, 32 * 1024 * 1024, FileKind::Photo, "jpg", "carved/photos"),
    sig!("PNG", b"\x89PNG\x0D\x0A\x1A\x0A", 0, Some(b"IEND\xAE\xB2\x60\x82"), None,
         128, 64 * 1024 * 1024, 32 * 1024 * 1024, FileKind::Photo, "png", "carved/photos"),
    sig!("GIF", b"GIF87a", 0, Some(b"\x00\x3B"), None,
         64, 32 * 1024 * 1024, 8 * 1024 * 1024, FileKind::Photo, "gif", "carved/photos"),
    sig!("GIF", b"GIF89a", 0, Some(b"\x00\x3B"), None,
         64, 32 * 1024 * 1024, 8 * 1024 * 1024, FileKind::Photo, "gif", "carved/photos"),
    sig!("PDF", b"%PDF-", 0, Some(b"%%EOF"), None,
         256, 512 * 1024 * 1024, 64 * 1024 * 1024, FileKind::Document, "pdf", "carved/documents"),
    sig!("ZIP", b"PK\x03\x04", 0, Some(b"PK\x05\x06"), None,
         128, 512 * 1024 * 1024, 64 * 1024 * 1024, FileKind::Archive, "zip", "carved/archives"),
    sig!("RAR", b"Rar!\x1A\x07\x00", 0, None, None,
         128, 512 * 1024 * 1024, 0, FileKind::Archive, "rar", "carved/archives"),
    sig!("MP4", b"ftyp", 4, None, None,
         4096, 4 * 1024 * 1024 * 1024, 0, FileKind::Video, "mp4", "carved/videos"),
    sig!("RIFF", b"RIFF", 0, None, Some(SizeField { rel_offset: 4, add: 8 }),
         256, 2 * 1024 * 1024 * 1024, 0, FileKind::Audio, "wav", "carved/audio"),
    sig!("NEF", b"II*\x00\x10\x00\x00\x00", 0, None, None,
         4096, 256 * 1024 * 1024, 0, FileKind::Raw, "nef", "carved/raw"),
];
