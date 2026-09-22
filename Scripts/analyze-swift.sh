#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
REPORT_DIR="$ROOT_DIR/.build/swiftlint-analysis"
mkdir -p "$REPORT_DIR"
BUILD_DIR="$(mktemp -d "$REPORT_DIR/build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Analyzer rules need complete compiler invocations, including the test targets.
# A separate scratch directory preserves the normal incremental build cache.
swift build --build-tests --scratch-path "$BUILD_DIR" -v -Xswiftc -disable-batch-mode \
    > "$REPORT_DIR/build.log" 2>&1 || {
        cat "$REPORT_DIR/build.log"
        exit 1
    }

./Scripts/swiftlint.sh analyze --compiler-log-path "$REPORT_DIR/build.log" \
    --reporter json > "$REPORT_DIR/analysis.json"
echo "Analyzer report: $REPORT_DIR/analysis.json"
