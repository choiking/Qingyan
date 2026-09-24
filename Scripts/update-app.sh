#!/bin/bash
# Keep the installed bundle directories in place: moving them to a dated .app
# backup can make macOS follow the old bundle when resolving privacy entries.
set -euo pipefail
test "$#" -eq 3 || { echo 'Usage: update-app.sh SOURCE.app TARGET.app BACKUP_DIR' >&2; exit 1; }
source_app="$1"
target_app="$2"
backup_root="$3"
expected_id='org.localinput.inputmethod.LocalInput'
test -d "$source_app" && test ! -L "$source_app"
test ! -L "$target_app"
codesign --verify --deep --strict "$source_app"
identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")
test "$identifier" = "$expected_id" || { echo 'Unexpected source application; installation stopped.' >&2; exit 1; }
if test -e "$target_app"; then
  test ! "$source_app" -ef "$target_app" || { echo 'Source and destination are the same application.' >&2; exit 1; }
  identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target_app/Contents/Info.plist")
  test "$identifier" = "$expected_id" || { echo 'Another app occupies the destination; installation stopped.' >&2; exit 1; }
  mkdir -p "$backup_root"
  backup_dir=$(mktemp -d "$backup_root/$(date +%Y%m%d-%H%M%S)-XXXXXX")
  # Archives cannot be registered as competing applications by LaunchServices.
  ditto -c -k --sequesterRsrc --keepParent "$target_app" "$backup_dir/LocalInput.zip"
  printf 'Backup: %s\n' "$backup_dir/LocalInput.zip"
fi
mkdir -p "$target_app"
# Replace files by rename, preserving outer AND nested .app directory identities.
# Checksums also catch rebuilt binaries whose size and timestamp did not change.
/usr/bin/rsync -a --checksum --delete "$source_app/" "$target_app/"
codesign --verify --deep --strict "$target_app"
