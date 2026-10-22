#!/usr/bin/env python3
"""mint_license_key.py — mint an Ed25519-signed Files Recovery Pro key.

Usage:
  scripts/mint_license_key.py --key <private_pem> [--days-valid 0] [--print-only]

Payload layout (recovery-core::license):
  bytes 0..7   "FRFPRO1"
  byte  7      flags (bit0 = perpetual)
  bytes 8..12  issued  u32 LE (unix days)
  bytes 12..16 expiry  u32 LE (unix days, 0 = never)   [requires bit0=0]
  bytes 16..20 reserved
The key string is FRF1-<base64url(payload[20] || signature[64])> grouped by 4.

Requires: openssl CLI. The private key never leaves this machine.
"""
import argparse
import base64
import datetime
import struct
import subprocess
import sys
import tempfile
import os

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", required=True, help="PEM private key (Ed25519)")
    ap.add_argument("--days-valid", type=int, default=0,
                    help="validity in days from today; 0 = perpetual")
    ap.add_argument("--issued", type=int, default=None, help="issued unix days override")
    args = ap.parse_args()

    issued = args.issued if args.issued is not None else (
        int(datetime.datetime.now(datetime.timezone.utc).timestamp()) // 86400)
    perpetual = args.days_valid == 0
    expiry = 0 if perpetual else issued + args.days_valid

    payload = b"FRFPRO1" + bytes([0b1 if perpetual else 0b0]) + \
        struct.pack("<II", issued, expiry) + b"\x00" * 4
    assert len(payload) == 20

    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(payload)
        msg_path = f.name
    try:
        sig = subprocess.run(
            ["openssl", "pkeyutl", "-sign", "-inkey", args.key, "-rawin", "-in", msg_path],
            capture_output=True, check=True).stdout
    finally:
        os.unlink(msg_path)
    if len(sig) != 64:
        print(f"unexpected signature length {len(sig)}", file=sys.stderr)
        return 1

    raw = payload + sig
    # standard base64 (alphabet has no dash, so dash-grouping is safe)
    body = base64.b64encode(raw).decode().rstrip("=")
    key = "FRF1-" + "-".join(body[i:i + 4] for i in range(0, len(body), 4))

    print("issued_days :", issued)
    print("expiry_days :", expiry or "never (perpetual)")
    print("key         :", key)
    print()
    print("paste-ready key above — verify locally with:")
    print("  cargo test -p recovery-core license::")
    return 0

if __name__ == "__main__":
    sys.exit(main())
