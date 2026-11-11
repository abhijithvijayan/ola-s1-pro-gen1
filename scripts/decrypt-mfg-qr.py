#!/usr/bin/env python3
"""decrypt-mfg-qr.py — Decrypt a scanned Manufacturing / Diagnostics QR.

After scripts/swap-mfg-keys.sh has replaced the on-device RSA public key, the
QR shown by HHMIC's Manufacturing / Version-History keypad is encrypted with
the local private key at local/mfg-keys/mfg.key. This script takes the scanned
base64 payload, decrypts it, and prints the 6-digit OTP (plus the full
plaintext for reference).

Plaintext format (from HHMIC's RSAEncryptor.generateEncoderData; the second
argument is appended before the first, so the order is OTP then VIN):

    "Manufacturing$<OTP>$<VIN>$<systemTimeMs>"
    "Diagnostics$<OTP>$<VIN>$<systemTimeMs>"

Usage:
  python3 scripts/decrypt-mfg-qr.py "<base64 blob>"
  python3 scripts/decrypt-mfg-qr.py --file qr.txt
  echo "<base64 blob>" | python3 scripts/decrypt-mfg-qr.py

Options:
  --key PATH   Private key path (default: local/mfg-keys/mfg.key)

Needs Python 3 and either the `cryptography` package (preferred) or
`pycryptodome`. Install one:

  pip install cryptography
  # or
  pip install pycryptodome
"""

from __future__ import annotations

import argparse
import base64
import os
import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_KEY = REPO_ROOT / "local" / "mfg-keys" / "mfg.key"


def read_blob(args: argparse.Namespace) -> str:
    """Pick the QR payload from arg, --file, or stdin, strip whitespace."""
    if args.file:
        raw = Path(args.file).read_text()
    elif args.blob:
        raw = args.blob
    elif not sys.stdin.isatty():
        raw = sys.stdin.read()
    else:
        sys.exit("No input. Pass the base64 blob, --file <path>, or pipe it in.")
    return re.sub(r"\s+", "", raw)


def decrypt(ciphertext: bytes, key_path: Path) -> bytes:
    """RSA/ECB/PKCS1Padding, matching HHMIC's RSAEncryptor.Encrypt."""
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import padding

        priv = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
        block = priv.key_size // 8
    except ImportError:
        try:
            from Crypto.PublicKey import RSA
            from Crypto.Cipher import PKCS1_v1_5
        except ImportError:
            sys.exit(
                "Install `cryptography` or `pycryptodome`:\n"
                "  pip install cryptography\n"
                "  pip install pycryptodome"
            )
        priv = RSA.import_key(key_path.read_bytes())
        cipher = PKCS1_v1_5.new(priv)
        block = priv.size_in_bytes()

        chunks = []
        for i in range(0, len(ciphertext), block):
            pt = cipher.decrypt(ciphertext[i:i + block], b"")
            if not pt:
                sys.exit(
                    f"Decrypt failed at offset {i}. The QR was likely encrypted "
                    "with a different key (stock or a stale swap). Re-run "
                    "scripts/swap-mfg-keys.sh and capture a fresh QR."
                )
            chunks.append(pt)
        return b"".join(chunks)

    chunks = []
    for i in range(0, len(ciphertext), block):
        chunks.append(priv.decrypt(ciphertext[i:i + block], padding.PKCS1v15()))
    return b"".join(chunks)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("blob", nargs="?", help="base64 QR payload (positional)")
    ap.add_argument("--file", help="read the base64 payload from this file")
    ap.add_argument("--key", default=str(DEFAULT_KEY), help=f"private key path (default: {DEFAULT_KEY})")
    args = ap.parse_args()

    key_path = Path(args.key)
    if not key_path.is_file():
        sys.exit(f"Private key not found: {key_path}\nRun scripts/swap-mfg-keys.sh first.")

    blob = read_blob(args)
    try:
        ciphertext = base64.b64decode(blob, validate=True)
    except Exception as e:
        sys.exit(f"Not valid base64: {e}")

    plaintext = decrypt(ciphertext, key_path).decode("utf-8", errors="replace")

    parts = plaintext.split("$")
    otp = None
    kind = vin = ts = ""
    if len(parts) >= 4 and parts[0] in ("Manufacturing", "Diagnostics"):
        kind, otp, vin, ts = parts[0], parts[1], parts[2], parts[3]

    print(f"Plaintext : {plaintext}")
    if otp:
        print(f"Kind      : {kind}")
        print(f"VIN       : {vin}")
        print(f"Timestamp : {ts}")
        print()
        print(f"OTP       : {otp}")
    else:
        print("\nDid not match the expected 'Manufacturing$OTP$VIN$timestamp' format.")
        print("Check that the scan captured the full QR and that the swap is active.")


if __name__ == "__main__":
    main()
