#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
python3 Scripts/bootstrap.py --verify-only
BUILD="$ROOT/build"
APP="$BUILD/LocalInput.app"
VOICE="$APP/Contents/Helpers/LocalInput Voice.app"
FRAMEWORK="$ROOT/Vendor/whisper/build-apple/whisper.xcframework/macos-arm64_x86_64"
mkdir -p "$BUILD/module-cache" "$APP/Contents/"{MacOS,Resources/Rime,Frameworks,Helpers} \
  "$VOICE/Contents/"{MacOS,Resources/Models,Frameworks}
SDK="$(xcrun --sdk macosx --show-sdk-path)"
export CLANG_MODULE_CACHE_PATH="$BUILD/module-cache"
export SWIFT_MODULECACHE_PATH="$BUILD/module-cache"
cp Resources/InputMethod-Info.plist "$APP/Contents/Info.plist"
cp Resources/Voice-Info.plist "$VOICE/Contents/Info.plist"
python3 Tests/BundlePermissionTests.py "$APP"
cp Vendor/rime/dist/lib/librime.1.17.0.dylib "$APP/Contents/Frameworks/librime.1.dylib"
# librime discovers plugins in a "rime-plugins" directory beside its own dylib.
mkdir -p "$APP/Contents/Frameworks/rime-plugins"
cp Vendor/rime/dist/lib/rime-plugins/librime-octagram.dylib "$APP/Contents/Frameworks/rime-plugins/"
ditto "$FRAMEWORK/whisper.framework" "$VOICE/Contents/Frameworks/whisper.framework"
cp Vendor/Models/ggml-small-q5_1.bin "$VOICE/Contents/Resources/Models/"
cp Vendor/luna-pinyin/*.yaml Vendor/prelude/*.yaml "$APP/Contents/Resources/Rime/"
cp Vendor/essay/essay.txt "$APP/Contents/Resources/Rime/"
# luna_pinyin.schema.yaml already carries an optional "grammar:/hant?" patch; these
# two files are what make it resolve. The vocabulary (essay.txt) is traditional, so
# the traditional model is the matching one even though output is simplified.
cp Vendor/octagram/grammar.yaml Vendor/octagram/zh-hant-t-essay-bgw.gram "$APP/Contents/Resources/Rime/"
ditto Vendor/rime/share/opencc "$APP/Contents/Resources/Rime/opencc"
cat > "$APP/Contents/Resources/Rime/default.custom.yaml" <<'YAML'
patch:
  schema_list:
    - schema: luna_pinyin_simp
  menu/page_size: 5
  switcher/hotkeys: []
YAML
mkdir -p "$APP/Contents/Resources/Licenses"
cp Vendor/RIME-LICENSE "$APP/Contents/Resources/Licenses/librime.txt"
cp Vendor/WHISPER-LICENSE "$APP/Contents/Resources/Licenses/whisper.cpp.txt"
for repo in luna-pinyin prelude essay; do
  if test -f "Vendor/$repo/LICENSE"; then cp "Vendor/$repo/LICENSE" "$APP/Contents/Resources/Licenses/$repo.txt"; fi
done
cp THIRD_PARTY.md "$APP/Contents/Resources/Licenses/"
cp Vendor/Licenses/* "$APP/Contents/Resources/Licenses/"
cp dependencies.lock.json "$APP/Contents/Resources/Licenses/"
xcrun clang -isysroot "$SDK" -fobjc-arc -mmacosx-version-min=14.0 -arch arm64 -c Sources/Bridge/RimeBridge.m \
  -I Vendor/rime/dist/include -o "$BUILD/RimeBridge.o"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  -module-cache-path "$BUILD/module-cache" -module-name LocalInput \
  -import-objc-header Sources/Bridge/RimeBridge.h \
  Sources/Shared/*.swift Sources/InputMethod/*.swift "$BUILD/RimeBridge.o" \
  -L "$APP/Contents/Frameworks" -l rime.1 -framework AppKit -framework InputMethodKit \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' -o "$APP/Contents/MacOS/LocalInput"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  -module-cache-path "$BUILD/module-cache" -module-name LocalInputVoice \
  Sources/Shared/*.swift Sources/Companion/*.swift \
  -F "$VOICE/Contents/Frameworks" -framework whisper -framework AppKit -framework SwiftUI -framework AVFoundation \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' -o "$VOICE/Contents/MacOS/LocalInputVoice"
mkdir -p "$BUILD/deploy-user"
"$APP/Contents/MacOS/LocalInput" --deploy-rime "$APP/Contents/Resources/Rime" "$BUILD/deploy-user"
ditto "$BUILD/deploy-user/build" "$APP/Contents/Resources/Rime/build"
xcrun swift Scripts/icon.swift "$APP/Contents/Resources/InputIcon-AdaptiveTemplate.tiff"
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/librime.1.dylib"
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/rime-plugins/librime-octagram.dylib"
codesign --force --sign - --timestamp=none "$VOICE/Contents/Frameworks/whisper.framework"
codesign --force --sign - --timestamp=none "$VOICE"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD/module-cache" Scripts/InputSource.swift -o "$BUILD/input-source"
printf 'Built: %s\n' "$APP"
