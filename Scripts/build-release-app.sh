#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for arg in "$@"; do
    case "$arg" in
        VERSION=*|BUILD=*|RELEASE_CHANNEL=*|ARCH=*|RELEASE_LABEL=*|DRY_RUN=*|SIGN_IDENTITY=*|ENABLE_HARDENED_RUNTIME=*|NOTARIZE=*|NOTARY_PROFILE=*|BUILD_DIR=*)
            export "$arg"
            ;;
        *)
            echo "error: unsupported argument '$arg'; use KEY=value overrides" >&2
            exit 1
            ;;
    esac
done

APP_NAME="GlassEQ"
APP_TARGET="GlassEQApp"
SETTINGS_APP_NAME="GlassEQSettings"
SETTINGS_APP_TARGET="GlassEQSettings"
source_plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$2"
}

VERSION="${VERSION:-$(source_plist_value CFBundleShortVersionString "$ROOT_DIR/Sources/GlassEQApp/Info.plist")}"
BUILD="${BUILD:-$(source_plist_value CFBundleVersion "$ROOT_DIR/Sources/GlassEQApp/Info.plist")}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-alpha}"
ARCH="${ARCH:-arm64}"
RELEASE_LABEL="${RELEASE_LABEL:-}"
DRY_RUN="${DRY_RUN:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
ENABLE_HARDENED_RUNTIME="${ENABLE_HARDENED_RUNTIME:-0}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build/release-app}"
ICON_FILE="$ROOT_DIR/Sources/GlassEQApp/Resources/GlassEQ.icns"
MIGRATION_PLIST="$ROOT_DIR/Sources/GlassEQApp/Resources/container-migration.plist"

fail() {
    echo "error: $*" >&2
    exit 1
}

verify_signed_entitlement() {
    local bundle_path="$1"
    local entitlement="$2"
    local escaped_entitlement="${entitlement//./\\.}"
    local value

    if ! value="$(
        codesign -d --entitlements :- "$bundle_path" 2>/dev/null |
            plutil -extract "$escaped_entitlement" raw -o - -
    )" || [[ "$value" != "true" ]]; then
        fail "signed bundle '$bundle_path' is missing required entitlement '$entitlement'"
    fi
}

verify_signed_entitlement_keys() {
    local bundle_path="$1"
    shift
    local actual_keys
    local expected_keys

    actual_keys="$(
        codesign -d --entitlements :- "$bundle_path" 2>/dev/null |
            plutil -convert json -o - - |
            python3 -c 'import json, sys; print("\n".join(sorted(json.load(sys.stdin))))'
    )" || fail "could not read signed entitlements from '$bundle_path'"
    expected_keys="$(printf '%s\n' "$@" | LC_ALL=C sort)"
    [[ "$actual_keys" == "$expected_keys" ]] ||
        fail "signed bundle '$bundle_path' has unexpected entitlements: $actual_keys"
}

is_dry_run() {
    [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" || "$DRY_RUN" == "yes" ]]
}

default_release_label() {
    if [[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.0$ ]]; then
        echo "${RELEASE_CHANNEL}-${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    else
        echo "${RELEASE_CHANNEL}-${VERSION}"
    fi
}

normalize_path() {
    python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=False))' "$1"
}

normalize_build_dir() {
    local input="$1"
    local normalized
    local build_root
    normalized="$(normalize_path "$input")"
    build_root="$(normalize_path "$ROOT_DIR/.build")"

    if [[ "$normalized" != "$build_root" && "$normalized" != "$build_root"/* ]]; then
        fail "BUILD_DIR must resolve under '$build_root'; got '$normalized'"
    fi

    echo "$normalized"
}

validate_inputs() {
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must match MAJOR.MINOR.PATCH; got '$VERSION'"
    [[ "$BUILD" =~ ^[1-9][0-9]*(\.(0|[1-9][0-9]*)){0,2}$ ]] || fail "BUILD must be a positive integer or dotted numeric build; got '$BUILD'"
    [[ "$RELEASE_LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || fail "RELEASE_LABEL must be 1-64 URL-safe label characters and start with a letter or number; got '$RELEASE_LABEL'"

    case "$ARCH" in
        arm64|x86_64) ;;
        *) fail "ARCH must be arm64 or x86_64; got '$ARCH'" ;;
    esac

    case "$RELEASE_CHANNEL" in
        alpha|production) ;;
        *) fail "RELEASE_CHANNEL must be alpha or production; got '$RELEASE_CHANNEL'" ;;
    esac

    if [[ "$RELEASE_CHANNEL" == "alpha" ]]; then
        [[ "$ARCH" == "arm64" ]] || fail "alpha builds are arm64-only"
        [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]] || fail "alpha builds must use ad hoc signing; unset SIGN_IDENTITY or set it to '-'"
        [[ "$ENABLE_HARDENED_RUNTIME" == "0" || "$ENABLE_HARDENED_RUNTIME" == "false" ]] || fail "alpha builds do not enable Hardened Runtime"
        [[ "$NOTARIZE" == "0" || "$NOTARIZE" == "false" ]] || fail "alpha builds are not notarized"
        [[ -z "$NOTARY_PROFILE" ]] || fail "alpha builds must not set NOTARY_PROFILE"
        SIGN_IDENTITY="-"
        return
    fi

    [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]] || fail "production builds require SIGN_IDENTITY='Developer ID Application: ...'"
    [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]] || fail "production SIGN_IDENTITY must be a Developer ID Application identity"
    [[ "$ENABLE_HARDENED_RUNTIME" == "1" || "$ENABLE_HARDENED_RUNTIME" == "true" ]] || fail "production builds require ENABLE_HARDENED_RUNTIME=1"
    [[ "$NOTARIZE" == "1" || "$NOTARIZE" == "true" ]] || fail "production builds require NOTARIZE=1"
    [[ -n "$NOTARY_PROFILE" ]] || fail "production notarization requires NOTARY_PROFILE"
}

derive_paths() {
    DIST_DIR="$ROOT_DIR/.build/dist"
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
    ZIP_PATH="$DIST_DIR/$APP_NAME-$RELEASE_LABEL-macos26-$ARCH.zip"
    CHECKSUM_PATH="$ZIP_PATH.sha256"
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

verify_macho_arch() {
    local binary="$1"
    local archs
    archs="$(lipo -archs "$binary")"

    if [[ " $archs " != *" $ARCH "* ]]; then
        fail "$binary does not contain requested ARCH '$ARCH' (found: $archs)"
    fi

    if [[ "$RELEASE_CHANNEL" == "alpha" && "$archs" != "arm64" ]]; then
        fail "alpha builds must be arm64-only (found: $archs)"
    fi
}

verify_plist_value() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")"
    [[ "$actual" == "$expected" ]] || fail "$plist $key is '$actual'; expected '$expected'"
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
RELEASE_LABEL="${RELEASE_LABEL:-$(default_release_label)}"
BUILD_DIR="$(normalize_build_dir "$BUILD_DIR")"
validate_inputs
derive_paths

if is_dry_run; then
    echo "Dry run passed."
    echo "Channel: $RELEASE_CHANNEL"
    echo "Arch: $ARCH"
    echo "Signing: $([[ "$SIGN_IDENTITY" == "-" ]] && echo "ad hoc" || echo "$SIGN_IDENTITY")"
    echo "Hardened Runtime: $ENABLE_HARDENED_RUNTIME"
    echo "Notarize: $NOTARIZE"
    echo "Zip: $ZIP_PATH"
    exit 0
fi

if [[ ! -f "$ICON_FILE" ]]; then
    swift "$ROOT_DIR/Scripts/generate-app-icon.swift" >/dev/null
fi

swift build -c release --arch "$ARCH" --product "$APP_NAME"
swift build -c release --arch "$ARCH" --product "$SETTINGS_APP_NAME"
BUILD_BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"
EXECUTABLE_SOURCE="$BUILD_BIN_DIR/$APP_NAME"
SETTINGS_EXECUTABLE_SOURCE="$BUILD_BIN_DIR/$SETTINGS_APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR" "$SETTINGS_MACOS_DIR" "$SETTINGS_RESOURCES_DIR" "$DIST_DIR"

cp "$EXECUTABLE_SOURCE" "$MACOS_DIR/$APP_NAME"
cp "$SETTINGS_EXECUTABLE_SOURCE" "$SETTINGS_MACOS_DIR/$SETTINGS_APP_NAME"
cp "$ROOT_DIR/Sources/GlassEQApp/Info.plist" "$INFO_PLIST"
cp "$ROOT_DIR/Sources/GlassEQSettings/Info.plist" "$SETTINGS_INFO_PLIST"
cp "$ICON_FILE" "$RESOURCES_DIR/GlassEQ.icns"
cp "$ICON_FILE" "$SETTINGS_RESOURCES_DIR/GlassEQ.icns"
cp "$MIGRATION_PLIST" "$RESOURCES_DIR/container-migration.plist"
copy_spm_resources "$BUILD_BIN_DIR" "$APP_NAME" "$APP_TARGET" "$RESOURCES_DIR"
copy_spm_resources "$BUILD_BIN_DIR" "$APP_NAME" "GlassEQSettingsUI" "$RESOURCES_DIR" 1
copy_spm_resources "$BUILD_BIN_DIR" "$SETTINGS_APP_NAME" "$SETTINGS_APP_TARGET" "$SETTINGS_RESOURCES_DIR" 0
copy_spm_resources "$BUILD_BIN_DIR" "$APP_NAME" "GlassEQSettingsUI" "$SETTINGS_RESOURCES_DIR" 1
[[ -d "$RESOURCES_DIR/GlassEQ_GlassEQSettingsUI.bundle" ]] || fail "GlassEQSettingsUI fallback resource bundle was not copied into the main app resources"
[[ -d "$SETTINGS_RESOURCES_DIR/GlassEQ_GlassEQSettingsUI.bundle" ]] || fail "GlassEQSettingsUI resource bundle was not copied into the settings helper resources"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :GlassEQReleaseLabel $RELEASE_LABEL" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$SETTINGS_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$SETTINGS_INFO_PLIST"
verify_plist_value "$INFO_PLIST" CFBundleShortVersionString "$VERSION"
verify_plist_value "$INFO_PLIST" CFBundleVersion "$BUILD"
verify_plist_value "$INFO_PLIST" GlassEQReleaseLabel "$RELEASE_LABEL"
verify_plist_value "$SETTINGS_INFO_PLIST" CFBundleShortVersionString "$VERSION"
verify_plist_value "$SETTINGS_INFO_PLIST" CFBundleVersion "$BUILD"
verify_no_unresolved_plist_tokens "$INFO_PLIST" "$SETTINGS_INFO_PLIST"

chmod +x "$MACOS_DIR/$APP_NAME"
chmod +x "$SETTINGS_MACOS_DIR/$SETTINGS_APP_NAME"
verify_macho_arch "$MACOS_DIR/$APP_NAME"
verify_macho_arch "$SETTINGS_MACOS_DIR/$SETTINGS_APP_NAME"

if [[ "$RELEASE_CHANNEL" == "alpha" ]]; then
    codesign \
        --force \
        --sign - \
        --identifier com.glasseq.app.settings \
        --entitlements "$ROOT_DIR/GlassEQSettings.entitlements" \
        "$SETTINGS_APP_DIR" >/dev/null
    codesign \
        --force \
        --sign - \
        --entitlements "$ROOT_DIR/GlassEQ.entitlements" \
        "$APP_DIR" >/dev/null
else
    codesign \
        --force \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        --timestamp \
        --identifier com.glasseq.app.settings \
        --entitlements "$ROOT_DIR/GlassEQSettings.entitlements" \
        "$SETTINGS_APP_DIR" >/dev/null
    codesign \
        --force \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        --timestamp \
        --entitlements "$ROOT_DIR/GlassEQ.entitlements" \
        "$APP_DIR" >/dev/null
fi

codesign --verify --strict --verbose=2 "$SETTINGS_APP_DIR" >/dev/null
codesign --verify --strict --verbose=2 "$APP_DIR" >/dev/null
verify_signed_entitlement "$APP_DIR" com.apple.security.app-sandbox
verify_signed_entitlement "$APP_DIR" com.apple.security.device.audio-input
verify_signed_entitlement "$APP_DIR" com.apple.security.files.user-selected.read-only
verify_signed_entitlement "$APP_DIR" com.apple.security.network.client
verify_signed_entitlement "$SETTINGS_APP_DIR" com.apple.security.app-sandbox
verify_signed_entitlement "$SETTINGS_APP_DIR" com.apple.security.inherit
verify_signed_entitlement_keys \
    "$SETTINGS_APP_DIR" \
    com.apple.security.app-sandbox \
    com.apple.security.inherit

if [[ "$RELEASE_CHANNEL" == "production" ]]; then
    NOTARY_ZIP="$DIST_DIR/$APP_NAME-$RELEASE_LABEL-macos26-$ARCH-notary-submit.zip"
    rm -f "$NOTARY_ZIP"
    ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP_DIR" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_DIR"
    codesign --verify --strict --verbose=2 "$SETTINGS_APP_DIR" >/dev/null
    codesign --verify --strict --verbose=2 "$APP_DIR" >/dev/null
    spctl --assess --type execute --verbose=4 "$APP_DIR"
fi

rm -f "$ZIP_PATH"
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP_DIR" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"

echo "App: $APP_DIR"
echo "Zip: $ZIP_PATH"
echo "Checksum: $CHECKSUM_PATH"
cat "$CHECKSUM_PATH"
echo
if [[ "$RELEASE_CHANNEL" == "alpha" ]]; then
    echo "Alpha verification:"
    echo "  lipo -archs \"$MACOS_DIR/$APP_NAME\""
    echo "  codesign -d --entitlements :- \"$APP_DIR\""
    echo "  spctl --assess --type execute --verbose=4 \"$APP_DIR\""
    echo "  Expected spctl result: rejected, because this build is ad hoc-signed and not notarized."
else
    echo "Production verification:"
    echo "  lipo -archs \"$MACOS_DIR/$APP_NAME\""
    echo "  codesign -d --entitlements :- \"$APP_DIR\""
    echo "  spctl --assess --type execute --verbose=4 \"$APP_DIR\""
fi
