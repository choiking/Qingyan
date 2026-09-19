#!/usr/bin/env python3
"""Fetch upstream Ice dictionaries and pin their revision/hash for the next build.

Only dictionary data and attribution are imported, never upstream executables.
Run build.sh, test.sh, and install.sh afterwards to apply the update.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REPO = "https://github.com/iDvel/rime-ice.git"
FILES = ["LICENSE", "README.md", "others/docs/Credits.md"] + [
    f"cn_dicts/{name}.dict.yaml" for name in ("8105", "41448", "base", "ext", "tencent", "others")
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="40-character upstream commit; defaults to current main")
    args = parser.parse_args()
    revision = args.revision
    if not revision:
        revision = subprocess.check_output(
            ["git", "ls-remote", REPO, "refs/heads/main"], text=True, timeout=60
        ).split()[0]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        parser.error("revision must be a full Git commit hash")
    manifest_path = ROOT / "dependencies.lock.json"
    manifest = json.loads(manifest_path.read_text())
    asset = next(item for item in manifest["assets"] if item["path"] == "rime-ice.tar.gz")
    url = f"https://codeload.github.com/iDvel/rime-ice/tar.gz/{revision}"
    vendor = ROOT / "Vendor"
    vendor.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ice-update-", dir=vendor) as scratch:
        archive = Path(scratch) / "rime-ice.tar.gz"
        subprocess.run([
            "curl", "--fail", "--location", "--retry", "3", "--max-time", "180",
            "--proto", "=https", "--proto-redir", "=https", url, "--output", str(archive)
        ], check=True)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        # Stage and validate every required file before touching current data.
        staged = Path(scratch) / "data"
        with tarfile.open(archive) as source:
            for name in FILES:
                member = source.getmember(f"rime-ice-{revision}/{name}")
                if not member.isfile() or member.size > 100 * 1024 * 1024:
                    raise ValueError(f"Invalid dictionary archive entry: {name}")
                data = source.extractfile(member).read()
                text = data.decode("utf-8-sig")
                if name.endswith(".dict.yaml") and ("\n...\n" not in text or "\t" not in text):
                    raise ValueError(f"Invalid Rime dictionary: {name}")
                target = staged / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
        destination = vendor / "rime-ice"
        # Keep the outgoing dictionaries so review-dictionary.py can diff the
        # update against them; the replace below is otherwise in place and
        # leaves nothing to compare.
        previous = vendor / "rime-ice-previous"
        if (destination / "cn_dicts").is_dir():
            shutil.rmtree(previous, ignore_errors=True)
            shutil.copytree(destination / "cn_dicts", previous / "cn_dicts")
        for name in FILES:
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            (staged / name).replace(target)
        archive.replace(vendor / asset["path"])
        asset.update(url=url, sha256=digest)
        pending = manifest_path.with_suffix(".json.pending")
        pending.write_text(json.dumps(manifest, indent=2) + "\n")
        pending.replace(manifest_path)
    print(f"Pinned Ice dictionary: {revision}")
    print("Review what changed: python3 Scripts/review-dictionary.py "
          f"--old {(vendor / 'rime-ice-previous' / 'cn_dicts').relative_to(ROOT)} "
          f"--new {(destination / 'cn_dicts').relative_to(ROOT)}")
    print("Apply with: bash Scripts/build.sh && bash Scripts/test.sh && bash Scripts/install.sh")


if __name__ == "__main__":
    main()
