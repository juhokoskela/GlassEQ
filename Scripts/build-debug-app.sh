#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="GlassEQ"
APP_TARGET="GlassEQApp"
SETTINGS_APP_NAME="GlassEQSettings"
SETTINGS_APP_TARGET="GlassEQSettings"
BUILD_DIR="$ROOT_DIR/.build/debug-app"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
SETTINGS_APP_DIR="$HELPERS_DIR/$SETTINGS_APP_NAME.app"
SETTINGS_CONTENTS_DIR="$SETTINGS_APP_DIR/Contents"
SETTINGS_MACOS_DIR="$SETTINGS_CONTENTS_DIR/MacOS"
SETTINGS_RESOURCES_DIR="$SETTINGS_CONTENTS_DIR/Resources"
SETTINGS_INFO_PLIST="$SETTINGS_CONTENTS_DIR/Info.plist"
ICON_FILE="$ROOT_DIR/Sources/GlassEQApp/Resources/GlassEQ.icns"
MIGRATION_PLIST="$ROOT_DIR/Sources/GlassEQApp/Resources/container-migration.plist"

fail() {
    echo "error: $*" >&2
    exit 1
}

copy_spm_resources() {
    local build_bin_dir="$1"
    local product_name="${2:-$APP_NAME}"
    local target_name="${3:-$APP_TARGET}"
    local destination_dir="${4:-$RESOURCES_DIR}"
    local warn_missing="${5:-1}"
    local copied=0
    local resource

    for resource in "$build_bin_dir"/${product_name}_${target_name}.resources "$build_bin_dir"/${product_name}_${target_name}.bundle; do
        [[ -e "$resource" ]] || continue
        cp -R "$resource" "$destination_dir/$(basename "$resource")"
        copied=1
    done

    if [[ "$copied" -eq 0 && "$warn_missing" == "1" ]]; then
        echo "warning: SwiftPM resource bundle was not found next to $product_name" >&2
    fi
}

verify_no_unresolved_plist_tokens() {
    local plist
    for plist in "$@"; do
        if grep -q '\$(' "$plist"; then
            fail "$plist contains unresolved build setting placeholders"
        fi
    done
}

cd "$ROOT_DIR"

swift build --product "$APP_NAME"
swift build --product "$SETTINGS_APP_NAME"
BUILD_BIN_DIR="$(swift build --show-bin-path)"
EXECUTABLE_SOURCE="$BUILD_BIN_DIR/$APP_NAME"
SETTINGS_EXECUTABLE_SOURCE="$BUILD_BIN_DIR/$SETTINGS_APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR" "$SETTINGS_MACOS_DIR" "$SETTINGS_RESOURCES_DIR"

cp "$EXECUTABLE_SOURCE" "$MACOS_DIR/$APP_NAME"
cp "$SETTINGS_EXECUTABLE_SOURCE" "$SETTINGS_MACOS_DIR/$SETTINGS_APP_NAME"
cp "$ROOT_DIR/Sources/GlassEQApp/Info.plist" "$INFO_PLIST"
cp "$ROOT_DIR/Sources/GlassEQSettings/Info.plist" "$SETTINGS_INFO_PLIST"
cp "$MIGRATION_PLIST" "$RESOURCES_DIR/container-migration.plist"
cp "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"
if [[ -f "$ICON_FILE" ]]; then
    cp "$ICON_FILE" "$RESOURCES_DIR/GlassEQ.icns"
    cp "$ICON_FILE" "$SETTINGS_RESOURCES_DIR/GlassEQ.icns"
fi
copy_spm_resources "$BUILD_BIN_DIR" "$APP_NAME" "$APP_TARGET" "$RESOURCES_DIR"
copy_spm_resources "$BUILD_BIN_DIR" "$APP_NAME" "GlassEQSettingsUI" "$RESOURCES_DIR" 1
copy_spm_resources "$BUILD_BIN_DIR" "$SETTINGS_APP_NAME" "$SETTINGS_APP_TARGET" "$SETTINGS_RESOURCES_DIR" 0
copy_spm_resources "$BUILD_BIN_DIR" "$APP_NAME" "GlassEQSettingsUI" "$SETTINGS_RESOURCES_DIR" 1
[[ -d "$RESOURCES_DIR/GlassEQ_GlassEQSettingsUI.bundle" ]] || fail "GlassEQSettingsUI fallback resource bundle was not copied into the main app resources"
[[ -d "$SETTINGS_RESOURCES_DIR/GlassEQ_GlassEQSettingsUI.bundle" ]] || fail "GlassEQSettingsUI resource bundle was not copied into the settings helper resources"
verify_no_unresolved_plist_tokens "$INFO_PLIST" "$SETTINGS_INFO_PLIST"

chmod +x "$MACOS_DIR/$APP_NAME"
chmod +x "$SETTINGS_MACOS_DIR/$SETTINGS_APP_NAME"

codesign --force --sign - --identifier com.glasseq.app.settings --entitlements "$ROOT_DIR/GlassEQSettings.entitlements" "$SETTINGS_APP_DIR" >/dev/null
codesign --force --sign - --entitlements "$ROOT_DIR/GlassEQ.entitlements" "$APP_DIR" >/dev/null
codesign --verify --strict --verbose=2 "$SETTINGS_APP_DIR" >/dev/null
codesign --verify --strict --verbose=2 "$APP_DIR" >/dev/null

echo "$APP_DIR"
