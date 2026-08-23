#!/usr/bin/env python3
"""
Set the Wake Panel password.

Prompts locally, derives a scrypt hash, and emits ONLY the hash plus a fresh
cookie secret. The plaintext never leaves this process - it is never written to
a file, a log, or an agent's conversation transcript.

Write it straight to the relay host:

    python set-password.py | ssh user@relay 'cat > /path/secrets/config.json && chmod 600 /path/secrets/config.json'

Or to a local path:

    python set-password.py -o ./secrets/config.json

Rotating the cookie secret invalidates existing sessions. That is intentional:
changing the password should log everyone out.
"""

import argparse
import getpass
import hashlib
import json
import os
import secrets
import sys

# n=2**14 keeps login well under 100ms on a low-power NAS while staying
# expensive to brute-force. Raise n if your relay host is fast.
SCRYPT = {"n": 2 ** 14, "r": 8, "p": 1, "dklen": 32}


def main():
    ap = argparse.ArgumentParser(description="Generate Wake Panel credentials.")
    ap.add_argument("-o", "--out", help="write JSON here instead of stdout")
    args = ap.parse_args()

    # Prompts go to stderr so `| ssh ...` keeps stdout pure JSON.
    def prompt(msg):
        return getpass.getpass(msg, stream=sys.stderr)

    pw = prompt("New Wake Panel password: ")
    if len(pw) < 8:
        sys.exit("Use at least 8 characters.")
    if pw != prompt("Confirm password: "):
        sys.exit("Passwords do not match.")

    salt = secrets.token_bytes(16)
    dk = hashlib.scrypt(pw.encode(), salt=salt, **SCRYPT)

    payload = json.dumps({
        "password_salt": salt.hex(),
        "password_hash": dk.hex(),
        "scrypt": SCRYPT,
        "cookie_secret": secrets.token_hex(32),
    }, indent=2)

    if args.out:
        path = os.path.abspath(args.out)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(payload + "\n")
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass    # Windows; ACLs are not POSIX modes
        print(f"Written to {path}", file=sys.stderr)
    else:
        print(payload)

    print("Restart the relay to apply.", file=sys.stderr)


if __name__ == "__main__":
    main()
