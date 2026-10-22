//! Ed25519-signed Pro license keys.
//!
//! The freemium gate needs an unlock that survives a public repo: the
//! verification key is EMBEDDED in the binary (public knowledge), while
//! signing keys stay with the founder. A key is `FRF1-` followed by the
//! standard-base64 (unpadded) encoding of
//!
//! ```text
//! payload[20] = "FRFPRO1" | flags u8 | issued u32 LE (unix days)
//!             | expiry u32 LE (unix days, 0 = never) | reserved u32
//! signature[64] = Ed25519(payload)
//! ```
//!
//! grouped into 4-character chunks — 84 bytes total, 112 base64
//! characters. The standard alphabet (A–Z a–z 0–9 + /) is required
//! because a dash-grouped key must never contain data dashes; decoding
//! strips dashes/whitespace first, then maps both base64 alphabets.
//!
//! The production identity can be overridden at build time with
//! `FRF_LICENSE_PUBKEY_B64` (base64url, 32 bytes) — CI and local builds
//! use the checked-in sample identity, whose private key is NOT in the
//! repository (see scripts/mint_license_key.py for minting).

use ed25519_dalek::{Signature, Signer, Verifier, VerifyingKey};

pub const KEY_PREFIX: &str = "FRF1";
const PAYLOAD_MAGIC: &[u8; 7] = b"FRFPRO1";
pub const PAYLOAD_LEN: usize = 20;
pub const SIG_LEN: usize = 64;

/// Decoded fields of a valid key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LicenseInfo {
    pub perpetual: bool,
    pub issued_days: u32,
    /// 0 = never expires.
    pub expiry_days: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LicenseError {
    /// Not decodable / wrong shape / wrong magic.
    Format,
    /// Well-formed but the signature does not verify.
    Signature,
    /// Signed and otherwise valid, but expired at [now_days].
    Expired,
}

/// The embedded verification identity (build-time override supported).
pub fn default_pubkey() -> [u8; 32] {
    // Sample identity's 32-byte public key, standard base64 (the value is
    // all-alphanumeric, so it is identical in both base64 alphabets).
    const SAMPLE_PUBKEY_B64: &str = "10btRq0726lnRq6Mof848s9c49dQlxhig9AuaCB9ff4";
    let b64 = option_env!("FRF_LICENSE_PUBKEY_B64").unwrap_or(SAMPLE_PUBKEY_B64);
    let mut out = [0u8; 32];
    let mut fallback = [0u8; 32];
    if decode_b64(b64, &mut out).is_ok() && out.iter().any(|&b| b != 0) {
        out
    } else {
        // decode_b64 cannot fail for the checked-in sample; still,
        // never panic — an all-zero key simply never verifies.
        let _ = decode_b64(SAMPLE_PUBKEY_B64, &mut fallback);
        fallback
    }
}

/// Verifies [key] against [pubkey]. [now_days] is the current unix day
/// number (passed in so tests are deterministic).
pub fn verify_license_key(
    key: &str,
    pubkey: &[u8; 32],
    now_days: u32,
) -> Result<LicenseInfo, LicenseError> {
    // Transport normalization: drop the prefix, dashes and whitespace.
    let compact: String = key
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .collect();
    let body = compact
        .strip_prefix(KEY_PREFIX)
        .ok_or(LicenseError::Format)?;

    let mut raw = [0u8; PAYLOAD_LEN + SIG_LEN];
    decode_b64(body, &mut raw).map_err(|_| LicenseError::Format)?;

    let (payload, sig_bytes) = raw.split_at(PAYLOAD_LEN);
    if &payload[0..7] != PAYLOAD_MAGIC {
        return Err(LicenseError::Format);
    }

    let vk = VerifyingKey::from_bytes(pubkey).map_err(|_| LicenseError::Format)?;
    let sig = Signature::from_slice(sig_bytes).map_err(|_| LicenseError::Format)?;
    vk.verify(payload, &sig).map_err(|_| LicenseError::Signature)?;

    let flags = payload[7];
    let issued = u32::from_le_bytes(payload[8..12].try_into().unwrap());
    let expiry = u32::from_le_bytes(payload[12..16].try_into().unwrap());
    let perpetual = flags & 0b1 != 0;
    if expiry != 0 && now_days > expiry {
        return Err(LicenseError::Expired);
    }
    Ok(LicenseInfo {
        perpetual,
        issued_days: issued,
        expiry_days: expiry,
    })
}

/// Serializes payload+signature into the user-facing key string.
pub fn assemble_key(payload: &[u8; PAYLOAD_LEN], sig: &[u8; SIG_LEN]) -> String {
    let mut raw = Vec::with_capacity(PAYLOAD_LEN + SIG_LEN);
    raw.extend_from_slice(payload);
    raw.extend_from_slice(sig);
    let mut body = encode_b64(&raw);
    // group into 4-char chunks
    let mut grouped = String::with_capacity(body.len() + body.len() / 4);
    while !body.is_empty() {
        let take = body.len().min(4);
        if !grouped.is_empty() {
            grouped.push('-');
        }
        grouped.push_str(&body[..take]);
        body.drain(..take);
    }
    format!("{KEY_PREFIX}-{grouped}")
}

/// Builds the 20-byte payload (kept public for the minting tool/test).
pub fn build_payload(flags: u8, issued_days: u32, expiry_days: u32) -> [u8; PAYLOAD_LEN] {
    let mut p = [0u8; PAYLOAD_LEN];
    p[0..7].copy_from_slice(PAYLOAD_MAGIC);
    p[7] = flags;
    p[8..12].copy_from_slice(&issued_days.to_le_bytes());
    p[12..16].copy_from_slice(&expiry_days.to_le_bytes());
    p
}

/// Standard-base64 (unpadded) decode into [out]; urlsafe characters are
/// tolerated. Returns the bytes written.
fn decode_b64(input: &str, out: &mut [u8]) -> Result<usize, ()> {
    let val = |c: u8| -> Result<u32, ()> {
        match c {
            b'A'..=b'Z' => Ok((c - b'A') as u32),
            b'a'..=b'z' => Ok((c - b'a' + 26) as u32),
            b'0'..=b'9' => Ok((c - b'0' + 52) as u32),
            b'+' => Ok(62),
            b'/' => Ok(63),
            // urlsafe leniency
            b'_' => Ok(62),
            b'-' => Ok(63),
            _ => Err(()),
        }
    };
    let bytes = input.as_bytes();
    let need = bytes.len() * 6 / 8;
    if need > out.len() {
        return Err(());
    }
    let mut acc: u32 = 0;
    let mut bits = 0u32;
    let mut written = 0usize;
    for &c in bytes {
        acc = (acc << 6) | val(c)?;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out[written] = ((acc >> bits) & 0xFF) as u8;
            acc &= (1 << bits) - 1; // drop consumed bits (no pollution)
            written += 1;
        }
    }
    // Trailing bits that are not a full byte must be zero (canonical).
    if bits > 0 && acc != 0 {
        return Err(());
    }
    Ok(written)
}

fn encode_b64(data: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [
            chunk[0],
            chunk.get(1).copied().unwrap_or(0),
            chunk.get(2).copied().unwrap_or(0),
        ];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        if chunk.len() > 1 {
            out.push(ALPHABET[(n >> 6) as usize & 63] as char);
        }
        if chunk.len() > 2 {
            out.push(ALPHABET[n as usize & 63] as char);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::SigningKey;

    const TODAY: u32 = 20_600; // ~2026-05

    fn signed_key(signer: &SigningKey, expiry_days: u32) -> String {
        let payload = build_payload(0b1, 20_500, expiry_days);
        let sig = signer.sign(&payload).to_bytes();
        assemble_key(&payload, &sig)
    }

    #[test]
    fn roundtrip_valid_perpetual_key() {
        let signer = SigningKey::from_bytes(&[7u8; 32]);
        let vk = signer.verifying_key().to_bytes();
        let key = signed_key(&signer, 0);
        let info = verify_license_key(&key, &vk, TODAY).unwrap();
        assert!(info.perpetual);
        assert_eq!(info.expiry_days, 0);
        // Paste-tolerant: surrounding whitespace survives.
        assert!(verify_license_key(&format!(" {} ", key), &vk, TODAY).is_ok());
    }

    #[test]
    fn expiry_is_enforced_against_now() {
        let signer = SigningKey::from_bytes(&[9u8; 32]);
        let vk = signer.verifying_key().to_bytes();
        let key = signed_key(&signer, 20_500);
        assert!(verify_license_key(&key, &vk, 20_400).is_ok());
        assert_eq!(
            verify_license_key(&key, &vk, 20_501),
            Err(LicenseError::Expired)
        );
    }

    #[test]
    fn tampered_payload_fails_signature() {
        let signer = SigningKey::from_bytes(&[11u8; 32]);
        let vk = signer.verifying_key().to_bytes();
        let payload = build_payload(0b1, 20_500, 0);
        let sig = signer.sign(&payload).to_bytes();
        // Same signature, different payload → verify must reject.
        let mut tampered = payload;
        tampered[7] ^= 0b10;
        let key = assemble_key(&tampered, &sig);
        assert_eq!(
            verify_license_key(&key, &vk, TODAY),
            Err(LicenseError::Signature)
        );
    }

    #[test]
    fn foreign_keypair_never_verifies() {
        let signer = SigningKey::from_bytes(&[12u8; 32]);
        let other = SigningKey::from_bytes(&[13u8; 32]);
        let key = signed_key(&signer, 0);
        assert_eq!(
            verify_license_key(&key, &other.verifying_key().to_bytes(), TODAY),
            Err(LicenseError::Signature)
        );
    }

    #[test]
    fn garbage_is_format_error() {
        assert_eq!(
            verify_license_key("FRF-ABCD-2345", &default_pubkey(), TODAY),
            Err(LicenseError::Format),
            "legacy dev-format keys are NOT license keys"
        );
        assert_eq!(verify_license_key("", &default_pubkey(), TODAY), Err(LicenseError::Format));
        assert_eq!(
            verify_license_key("FRF1-!!!!-!!!!", &default_pubkey(), TODAY),
            Err(LicenseError::Format)
        );
    }

    #[test]
    fn embedded_sample_pubkey_decodes() {
        let pk = default_pubkey();
        assert_eq!(pk.len(), 32);
        assert!(pk.iter().any(|&b| b != 0), "sample identity must not be all-zero");
    }
}
