"""Exercise upgrades on signed disposable bundles, without changing TCC or registration."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
identifier = "org.localinput.inputmethod.LocalInput"


def run(*args, succeeds=True):
    result = subprocess.run(args, capture_output=True, text=True)
    assert (result.returncode == 0) == succeeds, result.stdout + result.stderr


def bundle(path, bundle_id, version):
    contents = path / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    shutil.copy("/usr/bin/true", contents / "MacOS/TestApp")
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "TestApp",
                      "CFBundlePackageType": "APPL", "CFBundleVersion": version}, stream)
    resource = contents / "Resources/version.txt"
    resource.write_text(version)
    # Both releases intentionally have the same resource size and modification time.
    os.utime(resource, (1_700_000_000, 1_700_000_000))
    (contents / "Resources/current.txt").symlink_to("version.txt")


def release(path, version):
    bundle(path, identifier, version)
    helper = path / "Contents/Helpers/LocalInput Voice.app"
    bundle(helper, "org.localinput.Voice", version)
    if version == "1":
        (path / "Contents/Resources/obsolete.txt").write_text("old resource")
    for app in (helper, path):
        run("codesign", "--force", "--sign", "-", "--timestamp=none", str(app))


with tempfile.TemporaryDirectory(prefix="qingyan install test ") as directory:
    work = Path(directory)
    old = work / "old/LocalInput.app"
    new = work / "new/LocalInput.app"
    target = work / "Input Methods/LocalInput.app"
    backups = work / "Backups"
    release(old, "1")
    release(new, "2")

    def install(source, succeeds=True):
        run("bash", str(root / "Scripts/update-app.sh"), str(source), str(target), str(backups), succeeds=succeeds)

    install(old)
    tracked = [target, target / "Contents", target / "Contents/Helpers/LocalInput Voice.app"]
    inodes = [path.stat().st_ino for path in tracked]
    install(new)
    assert [path.stat().st_ino for path in tracked] == inodes, "An upgrade moved/recreated an installed bundle directory"
    assert (target / "Contents/Resources/version.txt").read_text() == "2", "Same-size/same-mtime resource was not updated"
    assert (target / "Contents/Resources/current.txt").is_symlink(), "Bundle symlink was lost"
    assert not (target / "Contents/Resources/obsolete.txt").exists(), "Stale signed resource remains"
    run("codesign", "--verify", "--deep", "--strict", str(target))

    archives = list(backups.glob("*/LocalInput.zip"))
    assert len(archives) == 1 and not list(backups.rglob("*.app")), "Backups contain a registerable application"
    restored = work / "restored"
    run("ditto", "-x", "-k", str(archives[0]), str(restored))
    restored_app = restored / "LocalInput.app"
    assert (restored_app / "Contents/Resources/version.txt").read_text() == "1", "Backup does not preserve the prior version"
    run("codesign", "--verify", "--deep", "--strict", str(restored_app))

    install(target, succeeds=False)
    (new / "Contents/Resources/version.txt").write_text("corrupt signature")
    install(new, succeeds=False)
    assert (target / "Contents/Resources/version.txt").read_text() == "2", "Invalid source changed the installed app"
    info_path = target / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleIdentifier"] = "org.example.unrelated"
    info_path.write_bytes(plistlib.dumps(info))
    install(old, succeeds=False)
    assert plistlib.loads(info_path.read_bytes())["CFBundleIdentifier"] == "org.example.unrelated", "Another application's bundle was overwritten"

print("PASS: install/upgrade preserves bundle identity, restores signed ZIP backup, removes stale files and rejects invalid targets/sources")
