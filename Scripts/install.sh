#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/LocalInput.app"
TARGET="$HOME/Library/Input Methods/LocalInput.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
test -d "$APP"
mkdir -p "$HOME/Library/Input Methods"
bash Scripts/update-app.sh "$APP" "$TARGET" "$HOME/Library/Application Support/LocalInput/Backups"
# Backups share the bundle IDs. Unregister them so privacy settings name the installed copy.
for old in "$HOME/Library/Application Support/LocalInput/Backups/"*.app; do
  # Fails harmlessly for copies that were never registered.
  "$LSREGISTER" -u "$old" 2>/dev/null || true
  "$LSREGISTER" -u "$old/Contents/Helpers/LocalInput Voice.app" 2>/dev/null || true
done
# The build copy should not compete with the installed copy for privacy UI resolution.
"$LSREGISTER" -u "$APP" 2>/dev/null || true
"$LSREGISTER" -u "$APP/Contents/Helpers/LocalInput Voice.app" 2>/dev/null || true
"$LSREGISTER" -f "$TARGET"
"$LSREGISTER" -f "$TARGET/Contents/Helpers/LocalInput Voice.app"
# Enable only after LaunchServices finishes registering the installed bundle.
"$PWD/build/input-source" register "$TARGET"
printf 'Installed: %s\nSelect 轻言输入法 in the input menu to try it.\n' "$TARGET"
