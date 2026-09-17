#!/usr/bin/env python3
"""Download only pinned, SHA-256-verified dependencies. No package manager needed."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
vendor = root / "Vendor"
parser = argparse.ArgumentParser()
parser.add_argument("--verify-only", action="store_true")
args = parser.parse_args()
manifest = json.loads((root / "dependencies.lock.json").read_text())

def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()

for asset in manifest["assets"]:
    path = vendor / asset["path"]
    if not path.is_file() or digest(path) != asset["sha256"]:
        if args.verify_only:
            sys.exit("Missing or corrupt dependency: " + str(path))
        path.parent.mkdir(parents=True, exist_ok=True)
        pending = path.with_suffix(path.suffix + ".download")
        print("Downloading", asset["path"], flush=True)
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--proto", "=https",
                        "--proto-redir", "=https", asset["url"], "--output", str(pending)], check=True)
        if digest(pending) != asset["sha256"]:
            pending.unlink()
            sys.exit("Checksum mismatch: " + asset["path"])
        pending.replace(path)
    if asset["extract_to"] and not args.verify_only:
        target = vendor / asset["extract_to"]
        target.mkdir(parents=True, exist_ok=True)
        if path.suffix == ".zip":
            subprocess.run(["ditto", "-xk", str(path), str(target)], check=True)
        else:
            subprocess.run(["tar", "-xf", str(path), "--strip-components=" + str(asset["strip_components"]),
                            "-C", str(target)], check=True)
print("Verified all dependency checksums.")
