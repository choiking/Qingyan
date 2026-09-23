#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VOICE="$PWD/build/LocalInput.app/Contents/Helpers/LocalInput Voice.app"
xcrun swiftc -swift-version 5 -O -module-cache-path build/module-cache \
  -import-objc-header Sources/Bridge/SherpaBridge.h -I Vendor/sherpa-onnx/include \
  Sources/Shared/LiveVoice.swift Sources/Companion/SpeechEngine.swift Tests/LiveSpeechTests.swift \
  -L "$VOICE/Contents/Frameworks" -l sherpa-onnx-c-api -framework AVFoundation \
  -Xlinker -rpath -Xlinker "$VOICE/Contents/Frameworks" -o build/live-speech-tests
build/live-speech-tests "$1" "$VOICE/Contents/Resources/Models/sense-voice/model.int8.onnx" "${2:-auto}"
