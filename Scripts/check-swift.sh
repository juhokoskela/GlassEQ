#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift format lint --strict --recursive Sources Tests Scripts Package.swift
./Scripts/swiftlint.sh lint --strict --quiet --reporter github-actions-logging
