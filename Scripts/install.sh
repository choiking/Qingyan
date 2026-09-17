#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/LocalInput.app"
TARGET="$HOME/Library/Input Methods/LocalInput.app"
test -d "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$HOME/Library/Input Methods"
if test -e "$TARGET"; then
  identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$TARGET/Contents/Info.plist")
  test "$identifier" = 'org.localinput.inputmethod.LocalInput' || { echo 'Another app occupies the destination; installation stopped.'; exit 1; }
  backup="$HOME/Library/Application Support/LocalInput/Backups/$(date +%Y%m%d-%H%M%S).app"
  mkdir -p "$(dirname "$backup")"
  mv "$TARGET" "$backup"
fi
ditto "$APP" "$TARGET"
"$PWD/build/input-source" register "$TARGET"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET/Contents/Helpers/LocalInput Voice.app"
printf 'Installed: %s\nSelect 轻言 Qingyan in the input menu to try it.\n' "$TARGET"
