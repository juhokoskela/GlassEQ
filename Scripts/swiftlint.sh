#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFTLINT_VERSION="0.65.1"
SWIFTLINT_SHA256="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"
TOOL_DIR="$ROOT_DIR/.build/tools/swiftlint/$SWIFTLINT_VERSION"

if [[ ! -x "$TOOL_DIR/swiftlint" ]]; then
    mkdir -p "$(dirname "$TOOL_DIR")"
    DOWNLOAD_DIR="$(mktemp -d "$(dirname "$TOOL_DIR")/download.XXXXXX")"
    trap 'rm -rf "$DOWNLOAD_DIR"' EXIT
    curl --fail --location --silent --show-error \
        "https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/portable_swiftlint.zip" \
        --output "$DOWNLOAD_DIR/swiftlint.zip"
    printf '%s  %s\n' "$SWIFTLINT_SHA256" "$DOWNLOAD_DIR/swiftlint.zip" | shasum -a 256 --check >&2
    ditto -x -k "$DOWNLOAD_DIR/swiftlint.zip" "$DOWNLOAD_DIR/tool"
    [[ "$("$DOWNLOAD_DIR/tool/swiftlint" version)" == "$SWIFTLINT_VERSION" ]]
    mv "$DOWNLOAD_DIR/tool" "$TOOL_DIR"
fi

cd "$ROOT_DIR"
"$TOOL_DIR/swiftlint" "$@"
