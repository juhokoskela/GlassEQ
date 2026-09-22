#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for arg in "$@"; do
    case "$arg" in
        VERSION=*|BUILD=*|RELEASE_CHANNEL=*|ARCH=*|RELEASE_LABEL=*|DRY_RUN=*|SIGN_IDENTITY=*|ENABLE_HARDENED_RUNTIME=*|NOTARIZE=*|NOTARY_PROFILE=*|BUILD_DIR=*|ENTITLEMENT_PUBLIC_KEYS_FILE=*)
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
RELEASE_CHANNEL="${RELEASE_CHANNEL:-beta}"
ARCH="${ARCH:-arm64}"
RELEASE_LABEL="${RELEASE_LABEL:-}"
DRY_RUN="${DRY_RUN:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
ENABLE_HARDENED_RUNTIME="${ENABLE_HARDENED_RUNTIME:-0}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build/release-app}"
# A JSON object of key identifier to base64 Ed25519 public key. Production builds must embed one
# so the app enforces licensing; a build without the dictionary runs unrestricted by design.
ENTITLEMENT_PUBLIC_KEYS_FILE="${ENTITLEMENT_PUBLIC_KEYS_FILE:-}"
ENTITLEMENT_PUBLIC_KEYS_INFO_KEY="GlassEQEntitlementPublicKeys"
ICON_FILE="$ROOT_DIR/Sources/GlassEQApp/Resources/GlassEQ.icns"
MIGRATION_PLIST="$ROOT_DIR/Sources/GlassEQApp/Resources/container-migration.plist"
LICENSE_FILE="$ROOT_DIR/LICENSE"
TRADEMARKS_FILE="$ROOT_DIR/TRADEMARKS.md"
SOURCE_REPOSITORY_URL="https://github.com/juhokoskela/GlassEQ"

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
        alpha|beta|production) ;;
        *) fail "RELEASE_CHANNEL must be alpha, beta, or production; got '$RELEASE_CHANNEL'" ;;
    esac

    if [[ "$RELEASE_CHANNEL" != "production" ]]; then
        [[ "$ARCH" == "arm64" ]] || fail "$RELEASE_CHANNEL builds are arm64-only"
        [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]] || fail "$RELEASE_CHANNEL builds must use ad hoc signing; unset SIGN_IDENTITY or set it to '-'"
        [[ "$ENABLE_HARDENED_RUNTIME" == "0" || "$ENABLE_HARDENED_RUNTIME" == "false" ]] || fail "$RELEASE_CHANNEL builds do not enable Hardened Runtime"
        [[ "$NOTARIZE" == "0" || "$NOTARIZE" == "false" ]] || fail "$RELEASE_CHANNEL builds are not notarized"
        [[ -z "$NOTARY_PROFILE" ]] || fail "$RELEASE_CHANNEL builds must not set NOTARY_PROFILE"
        SIGN_IDENTITY="-"
        return
    fi

    [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]] || fail "production builds require SIGN_IDENTITY='Developer ID Application: ...'"
    [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]] || fail "production SIGN_IDENTITY must be a Developer ID Application identity"
    [[ "$ENABLE_HARDENED_RUNTIME" == "1" || "$ENABLE_HARDENED_RUNTIME" == "true" ]] || fail "production builds require ENABLE_HARDENED_RUNTIME=1"
    [[ "$NOTARIZE" == "1" || "$NOTARIZE" == "true" ]] || fail "production builds require NOTARIZE=1"
    [[ -n "$NOTARY_PROFILE" ]] || fail "production notarization requires NOTARY_PROFILE"
    [[ -n "$ENTITLEMENT_PUBLIC_KEYS_FILE" ]] ||
        fail "production builds require ENTITLEMENT_PUBLIC_KEYS_FILE so the app enforces licensing"
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
    PACKAGE_DIR="$BUILD_DIR/package"
    PACKAGE_APP_DIR="$PACKAGE_DIR/$APP_NAME.app"
    PACKAGE_SETTINGS_APP_DIR="$PACKAGE_APP_DIR/Contents/Helpers/$SETTINGS_APP_NAME.app"
    SOURCE_ARCHIVE_NAME="$APP_NAME-$RELEASE_LABEL-source.tar.gz"
    SOURCE_ARCHIVE_PATH="$PACKAGE_DIR/$SOURCE_ARCHIVE_NAME"
    SOURCE_NOTICE_PATH="$PACKAGE_DIR/SOURCE.md"
    ZIP_PATH="$DIST_DIR/$APP_NAME-$RELEASE_LABEL-macos26-$ARCH.zip"
    CHECKSUM_PATH="$ZIP_PATH.sha256"
    DSYM_DIR="$BUILD_DIR/dSYMs"
    DSYM_ZIP_PATH="$DIST_DIR/$APP_NAME-$RELEASE_LABEL-macos26-$ARCH-dSYMs.zip"
    DMG_STAGING_DIR="$BUILD_DIR/dmg"
    DMG_MOUNT_DIR="$BUILD_DIR/dmg-mount"
    DMG_PATH="$DIST_DIR/$APP_NAME-$RELEASE_LABEL-macos26-$ARCH.dmg"
    DMG_CHECKSUM_PATH="$DMG_PATH.sha256"
    EVIDENCE_PATH="$DIST_DIR/$APP_NAME-$RELEASE_LABEL-macos26-$ARCH-release-evidence.md"
}

capture_source_revision() {
    local source_status

    [[ -f "$LICENSE_FILE" ]] || fail "release checkout is missing LICENSE"
    [[ -f "$TRADEMARKS_FILE" ]] || fail "release checkout is missing TRADEMARKS.md"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "release builds require a Git checkout"
    [[ ! -f "$ROOT_DIR/.gitmodules" ]] || fail "release source packaging does not yet support Git submodules"

    source_status="$(git status --porcelain=v1 --untracked-files=all)"
    [[ -z "$source_status" ]] || fail "release builds require a clean checkout so the Corresponding Source matches the binary"

    SOURCE_REVISION="$(git rev-parse --verify HEAD)"
}

verify_source_revision_unchanged() {
    local current_revision
    local source_status

    current_revision="$(git rev-parse --verify HEAD)"
    [[ "$current_revision" == "$SOURCE_REVISION" ]] || fail "Git HEAD changed during the release build"

    source_status="$(git status --porcelain=v1 --untracked-files=all)"
    [[ -z "$source_status" ]] || fail "the checkout changed during the release build"
}

create_source_archive() {
    local source_root="$APP_NAME-$RELEASE_LABEL-source"

    git archive \
        --format=tar.gz \
        --prefix="$source_root/" \
        --output="$SOURCE_ARCHIVE_PATH" \
        "$SOURCE_REVISION"

    tar -tzf "$SOURCE_ARCHIVE_PATH" | grep -Fx "$source_root/Package.swift" >/dev/null ||
        fail "Corresponding Source archive is missing Package.swift"
    tar -tzf "$SOURCE_ARCHIVE_PATH" | grep -Fx "$source_root/Scripts/build-release-app.sh" >/dev/null ||
        fail "Corresponding Source archive is missing the release script"
    tar -xOzf "$SOURCE_ARCHIVE_PATH" "$source_root/LICENSE" | cmp -s - "$LICENSE_FILE" ||
        fail "Corresponding Source archive does not contain the release license"

    {
        echo "# GlassEQ Corresponding Source"
        echo
        echo "This distribution was built from Git commit \`$SOURCE_REVISION\`."
        echo
        echo "The complete machine-readable Corresponding Source is included as \`$SOURCE_ARCHIVE_NAME\`."
        echo
        echo "Official repository: $SOURCE_REPOSITORY_URL"
        echo
        echo "Build inputs: version $VERSION, build $BUILD, channel $RELEASE_CHANNEL, architecture $ARCH, release label $RELEASE_LABEL."
        echo
        echo "GlassEQ is licensed under GPL-3.0-or-later. See \`LICENSE\` for the full license."
        echo
        echo "The GlassEQ name and logo are trademarks of Juho Koskela. See \`TRADEMARKS.md\` for the policy that applies to redistributed and modified builds."
    } > "$SOURCE_NOTICE_PATH"
}

verify_disk_image() {
    local mounted_app="$DMG_MOUNT_DIR/$APP_NAME.app"
    hdiutil verify -quiet "$DMG_PATH" || fail "disk image failed its integrity check"
    rm -rf "$DMG_MOUNT_DIR"
    mkdir -p "$DMG_MOUNT_DIR"
    hdiutil attach -readonly -nobrowse -noautoopen -quiet -mountpoint "$DMG_MOUNT_DIR" "$DMG_PATH"
    local failure=""
    [[ -d "$mounted_app" ]] || failure="disk image is missing $APP_NAME.app"
    [[ -n "$failure" || -L "$DMG_MOUNT_DIR/Applications" ]] || failure="disk image is missing the Applications link"
    [[ -n "$failure" ]] || cmp -s "$DMG_MOUNT_DIR/LICENSE" "$LICENSE_FILE" || failure="disk image contains the wrong license"
    [[ -n "$failure" || -f "$DMG_MOUNT_DIR/TRADEMARKS.md" ]] || failure="disk image is missing TRADEMARKS.md"
    [[ -n "$failure" || -f "$DMG_MOUNT_DIR/SOURCE.md" ]] || failure="disk image is missing SOURCE.md"
    [[ -n "$failure" || -f "$DMG_MOUNT_DIR/$SOURCE_ARCHIVE_NAME" ]] || failure="disk image is missing Corresponding Source"
    [[ -n "$failure" ]] || codesign --verify --strict --verbose=2 "$mounted_app" >/dev/null 2>&1 || failure="the app inside the disk image fails signature verification"
    if [[ -z "$failure" && "$RELEASE_CHANNEL" == "production" ]]; then
        xcrun stapler validate "$mounted_app" >/dev/null 2>&1 || failure="the app inside the disk image is not stapled"
    fi
    hdiutil detach -quiet "$DMG_MOUNT_DIR" || hdiutil detach -force -quiet "$DMG_MOUNT_DIR"
    rm -rf "$DMG_MOUNT_DIR"
    [[ -z "$failure" ]] || fail "$failure"
}

write_release_evidence() {
    {
        echo "# GlassEQ release evidence"
        echo
        echo "- Release label: $RELEASE_LABEL"
        echo "- Version: $VERSION ($BUILD)"
        echo "- Channel: $RELEASE_CHANNEL"
        echo "- Architecture: $ARCH"
        echo "- Source revision: $SOURCE_REVISION"
        echo "- Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "- Signing identity: $([[ "$SIGN_IDENTITY" == "-" ]] && echo "ad hoc" || echo "$SIGN_IDENTITY")"
        echo "- Hardened Runtime: $ENABLE_HARDENED_RUNTIME"
        echo "- App notarization submission: $APP_NOTARIZATION_ID"
        echo "- Disk image notarization submission: $DMG_NOTARIZATION_ID"
        echo "- Licensing: $(licensing_summary)"
        echo "- Xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
        echo "- Swift: $(swift --version 2>&1 | head -n 1)"
        echo "- $APP_NAME UUID: $(dwarfdump --uuid "$MACOS_DIR/$APP_NAME" | awk '{print $2}')"
        echo "- $SETTINGS_APP_NAME UUID: $(dwarfdump --uuid "$SETTINGS_MACOS_DIR/$SETTINGS_APP_NAME" | awk '{print $2}')"
        echo
        echo "## Artifacts (SHA-256)"
        echo
        echo "- $(basename "$ZIP_PATH"): $(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
        echo "- $(basename "$DMG_PATH"): $(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
        echo "- $(basename "$DSYM_ZIP_PATH"): $(shasum -a 256 "$DSYM_ZIP_PATH" | awk '{print $1}')"
    } > "$EVIDENCE_PATH"
}

verify_release_archive() {
    local source_root="$APP_NAME-$RELEASE_LABEL-source"

    unzip -tq "$ZIP_PATH" >/dev/null || fail "release archive failed its integrity check"
    unzip -Z1 "$ZIP_PATH" | grep -Fx "$APP_NAME.app/" >/dev/null || fail "release archive is missing $APP_NAME.app"
    unzip -Z1 "$ZIP_PATH" | grep -Fx "LICENSE" >/dev/null || fail "release archive is missing LICENSE"
    unzip -Z1 "$ZIP_PATH" | grep -Fx "SOURCE.md" >/dev/null || fail "release archive is missing SOURCE.md"
    unzip -Z1 "$ZIP_PATH" | grep -Fx "TRADEMARKS.md" >/dev/null || fail "release archive is missing TRADEMARKS.md"
    unzip -Z1 "$ZIP_PATH" | grep -Fx "$SOURCE_ARCHIVE_NAME" >/dev/null || fail "release archive is missing Corresponding Source"
    unzip -p "$ZIP_PATH" LICENSE | cmp -s - "$LICENSE_FILE" || fail "release archive contains the wrong license"
    unzip -p "$ZIP_PATH" "$APP_NAME.app/Contents/Resources/LICENSE" | cmp -s - "$LICENSE_FILE" ||
        fail "the packaged app contains the wrong license"
    unzip -p "$ZIP_PATH" "$SOURCE_ARCHIVE_NAME" |
        tar -xOzf - "$source_root/LICENSE" |
        cmp -s - "$LICENSE_FILE" || fail "packaged Corresponding Source contains the wrong license"
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

# Validates the keys file with the rules the app applies at launch: a non-empty JSON object whose
# values are canonical base64 of 32-byte Ed25519 public keys, and whose identifiers have no
# whitespace. The converted plist is what gets merged into Info.plist, so nothing is re-parsed
# from display output.
ENTITLEMENT_PUBLIC_KEYS_PLIST=""
validate_entitlement_public_keys_file() {
    local file="$1"
    [[ -f "$file" ]] || fail "ENTITLEMENT_PUBLIC_KEYS_FILE '$file' does not exist"
    ENTITLEMENT_PUBLIC_KEYS_PLIST="$(mktemp)"
    /usr/bin/python3 - "$file" "$ENTITLEMENT_PUBLIC_KEYS_PLIST" <<'PYTHON' || fail "ENTITLEMENT_PUBLIC_KEYS_FILE '$file' was rejected"
import base64, json, plistlib, sys

source, destination = sys.argv[1], sys.argv[2]
try:
    with open(source, "rb") as handle:
        keys = json.load(handle)
except Exception as error:
    sys.exit(f"error: ENTITLEMENT_PUBLIC_KEYS_FILE is not valid JSON: {error}")
if not isinstance(keys, dict) or not keys:
    sys.exit("error: ENTITLEMENT_PUBLIC_KEYS_FILE must be a non-empty JSON object of key identifier to public key")
for identifier, encoded in keys.items():
    if not identifier or any(character.isspace() for character in identifier):
        sys.exit(f"error: key identifier {identifier!r} must be non-empty without whitespace")
    if not isinstance(encoded, str):
        sys.exit(f"error: key {identifier!r} must be a base64 string")
    try:
        raw = base64.b64decode(encoded, validate=True)
    except Exception:
        sys.exit(f"error: key {identifier!r} is not strict base64")
    if len(raw) != 32 or base64.b64encode(raw).decode() != encoded:
        sys.exit(f"error: key {identifier!r} is not the canonical base64 of a 32-byte public key")
with open(destination, "wb") as handle:
    plistlib.dump(keys, handle)
PYTHON
}

embed_entitlement_public_keys() {
    local plist="$1"
    [[ -n "$ENTITLEMENT_PUBLIC_KEYS_PLIST" && -f "$ENTITLEMENT_PUBLIC_KEYS_PLIST" ]] ||
        fail "entitlement public keys were not validated before embedding"
    /usr/libexec/PlistBuddy -c "Delete :$ENTITLEMENT_PUBLIC_KEYS_INFO_KEY" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :$ENTITLEMENT_PUBLIC_KEYS_INFO_KEY dict" "$plist"
    /usr/libexec/PlistBuddy -c "Merge $ENTITLEMENT_PUBLIC_KEYS_PLIST :$ENTITLEMENT_PUBLIC_KEYS_INFO_KEY" "$plist"
}

# The licensing marker: a production build without the key dictionary would ship unrestricted.
verify_licensing_marker() {
    local plist="$1"
    [[ "$RELEASE_CHANNEL" == "production" ]] || return 0
    plutil -extract "$ENTITLEMENT_PUBLIC_KEYS_INFO_KEY" json -o - "$plist" 2>/dev/null |
        /usr/bin/python3 -c 'import json, sys; keys = json.load(sys.stdin); sys.exit(0 if isinstance(keys, dict) and keys else 1)' ||
        fail "production build is missing $ENTITLEMENT_PUBLIC_KEYS_INFO_KEY and would run unrestricted"
}

licensing_summary() {
    if [[ -n "$ENTITLEMENT_PUBLIC_KEYS_FILE" ]]; then
        echo "embedded from $ENTITLEMENT_PUBLIC_KEYS_FILE"
    elif [[ "$RELEASE_CHANNEL" == "production" ]]; then
        echo "required"
    else
        echo "none (unrestricted $RELEASE_CHANNEL build)"
    fi
}

verify_dsym_matches() {
    local binary="$1"
    local dsym="$2"
    local binary_uuid
    local dsym_uuid
    binary_uuid="$(dwarfdump --uuid "$binary" | awk '{print $2}')"
    dsym_uuid="$(dwarfdump --uuid "$dsym" | awk '{print $2}')"
    [[ -n "$binary_uuid" && "$binary_uuid" == "$dsym_uuid" ]] ||
        fail "dSYM UUID for $(basename "$binary") ($dsym_uuid) does not match the packaged binary ($binary_uuid)"
}

verify_macho_arch() {
    local binary="$1"
    local archs
    archs="$(lipo -archs "$binary")"

    if [[ " $archs " != *" $ARCH "* ]]; then
        fail "$binary does not contain requested ARCH '$ARCH' (found: $archs)"
    fi

    if [[ "$RELEASE_CHANNEL" != "production" && "$archs" != "arm64" ]]; then
        fail "$RELEASE_CHANNEL builds must be arm64-only (found: $archs)"
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
if [[ -n "$ENTITLEMENT_PUBLIC_KEYS_FILE" ]]; then
    validate_entitlement_public_keys_file "$ENTITLEMENT_PUBLIC_KEYS_FILE"
fi
derive_paths

if is_dry_run; then
    echo "Dry run passed."
    echo "Channel: $RELEASE_CHANNEL"
    echo "Arch: $ARCH"
    echo "Signing: $([[ "$SIGN_IDENTITY" == "-" ]] && echo "ad hoc" || echo "$SIGN_IDENTITY")"
    echo "Hardened Runtime: $ENABLE_HARDENED_RUNTIME"
    echo "Notarize: $NOTARIZE"
    echo "Zip: $ZIP_PATH"
    echo "Dmg: $DMG_PATH"
    echo "dSYMs: $DSYM_ZIP_PATH"
    echo "Licensing: $(licensing_summary)"
    exit 0
fi

capture_source_revision

if [[ ! -f "$ICON_FILE" ]]; then
    swift "$ROOT_DIR/Scripts/generate-app-icon.swift" >/dev/null
fi

swift build -c release --arch "$ARCH" --product "$APP_NAME"
swift build -c release --arch "$ARCH" --product "$SETTINGS_APP_NAME"
BUILD_BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"
EXECUTABLE_SOURCE="$BUILD_BIN_DIR/$APP_NAME"
SETTINGS_EXECUTABLE_SOURCE="$BUILD_BIN_DIR/$SETTINGS_APP_NAME"

# Symbols are linked from the object files SwiftPM keeps beside the release build. Crash reports
# from a shipped build can only be symbolicated with the dSYMs made from this exact link.
rm -rf "$DSYM_DIR"
mkdir -p "$DSYM_DIR"
dsymutil "$EXECUTABLE_SOURCE" -o "$DSYM_DIR/$APP_NAME.dSYM"
dsymutil "$SETTINGS_EXECUTABLE_SOURCE" -o "$DSYM_DIR/$SETTINGS_APP_NAME.dSYM"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR" "$SETTINGS_MACOS_DIR" "$SETTINGS_RESOURCES_DIR" "$DIST_DIR"

cp "$EXECUTABLE_SOURCE" "$MACOS_DIR/$APP_NAME"
cp "$SETTINGS_EXECUTABLE_SOURCE" "$SETTINGS_MACOS_DIR/$SETTINGS_APP_NAME"
cp "$ROOT_DIR/Sources/GlassEQApp/Info.plist" "$INFO_PLIST"
cp "$ROOT_DIR/Sources/GlassEQSettings/Info.plist" "$SETTINGS_INFO_PLIST"
cp "$ICON_FILE" "$RESOURCES_DIR/GlassEQ.icns"
cp "$LICENSE_FILE" "$RESOURCES_DIR/LICENSE"
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
if [[ -n "$ENTITLEMENT_PUBLIC_KEYS_FILE" ]]; then
    embed_entitlement_public_keys "$INFO_PLIST"
fi
verify_licensing_marker "$INFO_PLIST"

chmod +x "$MACOS_DIR/$APP_NAME"
chmod +x "$SETTINGS_MACOS_DIR/$SETTINGS_APP_NAME"
verify_macho_arch "$MACOS_DIR/$APP_NAME"
verify_macho_arch "$SETTINGS_MACOS_DIR/$SETTINGS_APP_NAME"

if [[ "$RELEASE_CHANNEL" != "production" ]]; then
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
verify_dsym_matches "$MACOS_DIR/$APP_NAME" "$DSYM_DIR/$APP_NAME.dSYM"
verify_dsym_matches "$SETTINGS_MACOS_DIR/$SETTINGS_APP_NAME" "$DSYM_DIR/$SETTINGS_APP_NAME.dSYM"
verify_signed_entitlement "$APP_DIR" com.apple.security.app-sandbox
verify_signed_entitlement "$APP_DIR" com.apple.security.device.audio-input
verify_signed_entitlement "$APP_DIR" com.apple.security.files.user-selected.read-write
verify_signed_entitlement "$APP_DIR" com.apple.security.network.client
verify_signed_entitlement_keys \
    "$APP_DIR" \
    com.apple.security.app-sandbox \
    com.apple.security.device.audio-input \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.network.client
verify_signed_entitlement "$SETTINGS_APP_DIR" com.apple.security.app-sandbox
verify_signed_entitlement "$SETTINGS_APP_DIR" com.apple.security.inherit
verify_signed_entitlement_keys \
    "$SETTINGS_APP_DIR" \
    com.apple.security.app-sandbox \
    com.apple.security.inherit

APP_NOTARIZATION_ID="not notarized"
DMG_NOTARIZATION_ID="not notarized"
notarize() {
    local artifact="$1"
    local result
    result="$(mktemp)"
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$result"
    local status
    status="$(plutil -extract status raw -o - "$result")"
    [[ "$status" == "Accepted" ]] || fail "notarization of $(basename "$artifact") ended with status '$status'"
    plutil -extract id raw -o - "$result"
    rm -f "$result"
}

if [[ "$RELEASE_CHANNEL" == "production" ]]; then
    NOTARY_ZIP="$DIST_DIR/$APP_NAME-$RELEASE_LABEL-macos26-$ARCH-notary-submit.zip"
    rm -f "$NOTARY_ZIP"
    ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP_DIR" "$NOTARY_ZIP"
    APP_NOTARIZATION_ID="$(notarize "$NOTARY_ZIP")"
    xcrun stapler staple "$APP_DIR"
    codesign --verify --strict --verbose=2 "$SETTINGS_APP_DIR" >/dev/null
    codesign --verify --strict --verbose=2 "$APP_DIR" >/dev/null
    spctl --assess --type execute --verbose=4 "$APP_DIR"
fi

verify_source_revision_unchanged
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"
ditto "$APP_DIR" "$PACKAGE_APP_DIR"
codesign --verify --strict --verbose=2 "$PACKAGE_SETTINGS_APP_DIR" >/dev/null
codesign --verify --strict --verbose=2 "$PACKAGE_APP_DIR" >/dev/null
if [[ "$RELEASE_CHANNEL" == "production" ]]; then
    xcrun stapler validate "$PACKAGE_APP_DIR"
fi
cp "$LICENSE_FILE" "$PACKAGE_DIR/LICENSE"
cp "$TRADEMARKS_FILE" "$PACKAGE_DIR/TRADEMARKS.md"
create_source_archive

rm -f "$ZIP_PATH"
ditto -c -k --norsrc --noextattr --noqtn --noacl "$PACKAGE_DIR" "$ZIP_PATH"
verify_release_archive
shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"
rm -f "$DSYM_ZIP_PATH"
ditto -c -k --norsrc --noextattr --noqtn --noacl "$DSYM_DIR" "$DSYM_ZIP_PATH"

# The disk image is the supported delivery artifact: the app, an Applications link for the drag
# install, and the same license and Corresponding Source access as the zip.
rm -rf "$DMG_STAGING_DIR"
ditto "$PACKAGE_DIR" "$DMG_STAGING_DIR"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO -quiet "$DMG_PATH"
if [[ "$RELEASE_CHANNEL" == "production" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
    DMG_NOTARIZATION_ID="$(notarize "$DMG_PATH")"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
fi
verify_disk_image
shasum -a 256 "$DMG_PATH" > "$DMG_CHECKSUM_PATH"
write_release_evidence

echo "App: $APP_DIR"
echo "Zip: $ZIP_PATH"
echo "Dmg: $DMG_PATH"
echo "dSYMs: $DSYM_ZIP_PATH"
echo "Evidence: $EVIDENCE_PATH"
echo "Licensing: $(licensing_summary)"
echo "Source revision: $SOURCE_REVISION"
echo "Corresponding Source: $SOURCE_ARCHIVE_NAME (inside the release Zip)"
echo "Checksum: $CHECKSUM_PATH"
cat "$CHECKSUM_PATH"
echo
echo "Release verification ($RELEASE_CHANNEL):"
echo "  lipo -archs \"$MACOS_DIR/$APP_NAME\""
echo "  codesign -d --entitlements :- \"$APP_DIR\""
echo "  spctl --assess --type execute --verbose=4 \"$APP_DIR\""
if [[ "$RELEASE_CHANNEL" != "production" ]]; then
    echo "  Expected spctl result: rejected, because this build is ad hoc-signed and not notarized."
fi
