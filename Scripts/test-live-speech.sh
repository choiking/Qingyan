#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VOICE="$PWD/build/LocalInput.app/Contents/Helpers/LocalInput Voice.app"
xcrun swiftc -swift-version 5 -O -module-cache-path build/module-cache \
  Sources/Shared/LiveVoice.swift Sources/Companion/SpeechEngine.swift Tests/LiveSpeechTests.swift \
  -F "$VOICE/Contents/Frameworks" -framework whisper -framework AVFoundation \
  -Xlinker -rpath -Xlinker "$VOICE/Contents/Frameworks" -o build/live-speech-tests
build/live-speech-tests "$1" "$VOICE/Contents/Resources/Models/ggml-small-q5_1.bin" "${2:-auto}" "${3:-}"
