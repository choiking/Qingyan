#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swiftc -swift-version 5 -O -module-cache-path build/module-cache \
  Sources/Shared/*.swift Sources/Companion/LocalCorrector.swift Tests/LocalCorrectionTests.swift \
  -o build/local-correction-tests
build/local-correction-tests
