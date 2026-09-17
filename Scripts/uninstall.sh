#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="$HOME/Library/Input Methods/LocalInput.app"
if test -d "$TARGET"; then
  identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$TARGET/Contents/Info.plist")
  test "$identifier" = 'org.localinput.inputmethod.LocalInput' || { echo 'Unexpected app identifier; uninstall stopped.'; exit 1; }
  "$PWD/build/input-source" disable
  destination="$HOME/.Trash/LocalInput-$(date +%Y%m%d-%H%M%S).app"
  mv "$TARGET" "$destination"
  printf 'Moved application to Trash: %s\n' "$destination"
fi
echo 'Local vocabulary and settings are preserved in ~/Library/Application Support/LocalInput. Log out and back in if macOS keeps the input method running.'
