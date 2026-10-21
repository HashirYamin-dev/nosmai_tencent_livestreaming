#!/usr/bin/env python3
"""Generate short-lived TRTC QA credentials on the developer's computer only.

Protocol reference: Tencent-RTC/tls-sig-api-v2-python, TLS signature v2.
No network requests, third-party Python packages, or stored SecretKey.
These are test user credentials, not a production authentication server.
"""
from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import zlib
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
USER_RE = re.compile(r"[A-Za-z0-9_-]{1,32}\Z")
PROFILE_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]{0,31}\Z")


def validate_identity(sdk_app_id: int, user_id: str) -> None:
    if isinstance(sdk_app_id, bool) or not 0 < sdk_app_id <= 0xFFFFFFFF:
        raise ValueError("SDKAppID must be a positive 32-bit application ID, not your account number.")
    if not USER_RE.fullmatch(user_id):
        raise ValueError("User ID must be 1-32 ASCII letters, digits, underscores or hyphens.")


def generate_usersig(sdk_app_id: int, secret_key: str, user_id: str,
                     expires_in: int = 7 * 86400, now: int | None = None) -> str:
    validate_identity(sdk_app_id, user_id)
    if not secret_key or not secret_key.strip():
        raise ValueError("SDKSecretKey cannot be empty.")
    if not 1 <= expires_in <= 7 * 86400:
        raise ValueError("This QA tool limits token lifetime to at most seven days.")
    issued_at = int(time.time()) if now is None else int(now)
    payload = (
        f"TLS.identifier:{user_id}\n"
        f"TLS.sdkappid:{sdk_app_id}\n"
        f"TLS.time:{issued_at}\n"
        f"TLS.expire:{expires_in}\n"
    ).encode("utf-8")
    digest = hmac.new(secret_key.encode("utf-8"), payload, hashlib.sha256).digest()
    body = {
        "TLS.ver": "2.0", "TLS.identifier": user_id,
        "TLS.sdkappid": sdk_app_id, "TLS.expire": expires_in,
        "TLS.time": issued_at, "TLS.sig": base64.b64encode(digest).decode("ascii"),
    }
    packed = zlib.compress(json.dumps(body, separators=(",", ":")).encode("utf-8"))
    # Tencent's alphabet is NOT Python urlsafe_b64encode's alphabet.
    return base64.b64encode(packed).decode("ascii").translate(str.maketrans("+/=", "*-_"))


def read_metadata(user_sig: str) -> dict:
    """Decode metadata only. This does NOT verify the HMAC or service access."""
    if not user_sig or len(user_sig) > 8192:
        raise ValueError("UserSig is empty or too long.")
    try:
        raw = user_sig.translate(str.maketrans("*-_", "+/="))
        compressed = base64.b64decode(raw, validate=True)
        inflater = zlib.decompressobj()
        unpacked = inflater.decompress(compressed, 32768)
        if not inflater.eof or inflater.unconsumed_tail:
            raise ValueError("Invalid or excessive UserSig payload.")
        body = json.loads(unpacked)
        if not isinstance(body, dict) or body.get("TLS.ver") != "2.0":
            raise ValueError("Expected a Tencent TLS v2 UserSig.")
        return body
    except (ValueError, TypeError, zlib.error, UnicodeError) as exc:
        raise ValueError("Could not decode a valid Tencent TLS v2 UserSig.") from exc


def make_config(sdk_app_id: int, user_id: str, user_sig: str) -> dict:
    validate_identity(sdk_app_id, user_id)
    metadata = read_metadata(user_sig)
    if metadata.get("TLS.sdkappid") != sdk_app_id:
        raise ValueError("This UserSig belongs to a different SDKAppID.")
    if metadata.get("TLS.identifier") != user_id:
        raise ValueError("This UserSig belongs to a different User ID.")
    expiry = int(metadata["TLS.time"]) + int(metadata["TLS.expire"])
    if expiry <= int(time.time()):
        raise ValueError("This UserSig has already expired. Generate a new one.")
    return {"SDK_APP_ID": sdk_app_id, "USER_ID": user_id,
            "USER_SIG": user_sig, "TOKEN_EXPIRES_AT": expiry}


def write_config(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.parent.is_symlink() or path.is_symlink():
        raise ValueError("Refusing to write credentials through a symbolic link.")
    handle, temp_name = tempfile.mkstemp(prefix=".trtc-", dir=path.parent)
    try:
        os.fchmod(handle, 0o600)
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manual", action="store_true", help="Paste console-generated UserSigs instead of a SecretKey.")
    parser.add_argument("--days", type=int, default=7, choices=range(1, 8), metavar="1..7")
    parser.add_argument("--profile", help="Generate one additional device profile, for example viewer2.")
    parser.add_argument("--user-id", help="Required with --profile; each simultaneous device needs a unique User ID.")
    args = parser.parse_args()
    if bool(args.profile) != bool(args.user_id):
        parser.error("--profile and --user-id must be supplied together.")
    if args.profile and not PROFILE_RE.fullmatch(args.profile):
        parser.error("Invalid profile name.")
    try:
        sdk_app_id = int(input("Tencent application SDKAppID: ").strip())
        profiles = [(args.profile, args.user_id)] if args.profile else [
            ("host", "host_001"), ("viewer", "viewer_001")]
        for _, user_id in profiles:
            validate_identity(sdk_app_id, user_id)
        print("Local QA only. Tokens are stored in ignored config/*.json files.")
        key = None if args.manual else getpass.getpass("SDKSecretKey (hidden; never saved): ").strip()
        issued_at = int(time.time())
        configs = []
        for profile, user_id in profiles:
            if args.manual:
                print(f"In Tencent UserSig Tools, generate a UserSig for User ID: {user_id}")
                sig = getpass.getpass(f"UserSig for {user_id} (hidden): ").strip()
            else:
                sig = generate_usersig(sdk_app_id, key or "", user_id, args.days * 86400, issued_at)
            configs.append((profile, make_config(sdk_app_id, user_id, sig)))
        # Validate every profile before replacing any existing config.
        for profile, config in configs:
            write_config(ROOT / "config" / f"{profile}.json", config)
            expiry = datetime.fromtimestamp(config["TOKEN_EXPIRES_AT"], timezone.utc)
            print(f"Created config/{profile}.json | User: {config['USER_ID']} | expires: {expiry.isoformat()}")
        key = None
        print("SecretKey was not saved or embedded in the Flutter app.")
        print("Next: flutter devices, then bash run.sh host DEVICE_ID / bash run.sh viewer DEVICE_ID")
        return 0
    except (ValueError, KeyError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    except (KeyboardInterrupt, EOFError):
        print("\nConfiguration cancelled.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
