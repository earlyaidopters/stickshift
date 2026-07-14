#!/bin/bash
# Build + run the deterministic core test suite.
set -e
cd "$(dirname "$0")/.."
FW="-framework Foundation -framework AppKit -framework ApplicationServices \
    -framework CoreGraphics -framework Carbon -framework Security"
CORE="src/core/Proc.m src/core/AXState.m src/core/Manifest.m src/core/Inject.m \
      src/core/Config.m src/core/Attribution.m src/core/Protocol.m src/core/Switch.m"
mkdir -p bin
clang -fobjc-arc -Wall -Isrc/core $FW $CORE tests/core_test.m -o bin/core_test
exec ./bin/core_test
