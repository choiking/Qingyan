"""TCC attributes this nested voice helper to the outer input-method application."""
from pathlib import Path
import plistlib
import sys

root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "build/LocalInput.app"
for path in [
    root / "Resources/InputMethod-Info.plist",
    root / "Resources/Voice-Info.plist",
    app / "Contents/Info.plist",
    app / "Contents/Helpers/LocalInput Voice.app/Contents/Info.plist",
]:
    with path.open("rb") as stream:
        info = plistlib.load(stream)
    message = info.get("NSMicrophoneUsageDescription")
    assert isinstance(message, str) and message.strip(), f"Missing microphone purpose string: {path}"
print("PASS: microphone purpose string in both source and built outer/helper application plists")
