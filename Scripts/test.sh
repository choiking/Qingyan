#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/LocalInput.app"
mkdir -p build/test-user
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun clang -isysroot "$SDK" -fobjc-arc -arch arm64 -mmacosx-version-min=14.0 Tests/RimeTests.m build/RimeBridge.o \
  -I Sources/Bridge -L "$APP/Contents/Frameworks" -l rime.1 -framework Foundation \
  -Wl,-rpath,"$APP/Contents/Frameworks" -o build/rime-tests
build/rime-tests "$APP/Contents/Resources/Rime" "$ROOT/build/test-user"
xcrun swiftc -swift-version 5 -module-cache-path build/module-cache Sources/Shared/*.swift Tests/StateTests.swift -o build/state-tests
xcrun swiftc -swift-version 5 -module-cache-path build/module-cache Sources/Shared/LiveVoice.swift Tests/LiveVoiceTests.swift -o build/live-voice-tests
build/live-voice-tests
build/state-tests
xcrun swiftc -swift-version 5 -module-cache-path build/module-cache Sources/Shared/*.swift Tests/JevTests.swift -o build/jev-tests
build/jev-tests
xcrun swiftc -swift-version 5 -module-cache-path build/module-cache Sources/Shared/*.swift Tests/CorrectionTests.swift -o build/correction-tests
build/correction-tests
xcrun swiftc -swift-version 5 -module-cache-path build/module-cache Sources/Shared/*.swift Tests/CustomPhraseTests.swift -o build/custom-phrase-tests
build/custom-phrase-tests "$APP/Contents/Resources/Rime/luna_pinyin.dict.yaml" build/custom-phrase-test
plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Helpers/LocalInput Voice.app/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
python3 Tests/BundlePermissionTests.py "$APP"
