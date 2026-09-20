#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/glasseq-ring-tsan.XXXXXX")"
trap 'rm -rf "$AUDIT_DIR"' EXIT

# Swift 6.4 crashes compiling EQProcessor under TSan. Compile the actual ring and
# its tests in isolation so that compiler failure cannot hide ring races in CI.
mkdir -p "$AUDIT_DIR/Sources/GlassEQAudio" "$AUDIT_DIR/Tests/GlassEQAudioTests"
cp "$ROOT_DIR/Sources/GlassEQAudio/RealtimeAudioRingBuffer.swift" "$AUDIT_DIR/Sources/GlassEQAudio/"
cp "$ROOT_DIR/Tests/GlassEQAudioTests/RealtimeAudioRingBufferTests.swift" "$AUDIT_DIR/Tests/GlassEQAudioTests/"
cat > "$AUDIT_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "RingAudit",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "GlassEQAudio"),
        .testTarget(name: "GlassEQAudioTests", dependencies: ["GlassEQAudio"])
    ],
    swiftLanguageModes: [.v6]
)
SWIFT
swift test --package-path "$AUDIT_DIR" --sanitize=thread
