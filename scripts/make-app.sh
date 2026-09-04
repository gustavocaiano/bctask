#!/bin/sh
# Assembles and ad-hoc-signs BCTask.app from `swift build` output.
#
# Usage: scripts/make-app.sh [debug|release]   (default: debug)
# Output: .build/BCTask.app
#
# Requires: Swift command line tools (swift build), plutil, iconutil, file,
# otool, and codesign.
# Verification: the script fails unless the bundle Info.plist carries
# LSUIElement=true, LSMinimumSystemVersion=13.0, and a valid BCTask.icns;
# the executable's Mach-O build metadata must report minimum OS 13.0.
set -eu
expected_minos="13.0"

root="$(cd "$(dirname "$0")/.." && pwd)"
config="debug"
case "${1:-}" in
    ""|debug) config="debug" ;;
    release) config="release" ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 64 ;;
esac

cd "$root"

echo "==> swift build -c $config"
swift build -c "$config"

bin_path="$(swift build -c "$config" --show-bin-path)"
app_path="$root/.build/BCTask.app"
plist_path="$app_path/Contents/Info.plist"
macho_path="$app_path/Contents/MacOS/BCTask"
icon_source="$root/Support/BCTask.icns"
icon_path="$app_path/Contents/Resources/BCTask.icns"

echo "==> assembling $app_path from $bin_path/BCTask"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path/BCTask" "$macho_path"
cp "$root/Support/Info.plist" "$plist_path"
if [ ! -s "$icon_source" ]; then
    echo "FAIL: app icon source is missing or empty: $icon_source" >&2
    exit 1
fi
cp "$icon_source" "$icon_path"
chmod +x "$macho_path"

echo "==> verifying app icon before signing"
icon_name="$(plutil -extract CFBundleIconFile raw "$plist_path")"
if [ "$icon_name" != "BCTask.icns" ]; then
    echo "FAIL: CFBundleIconFile must be BCTask.icns, got '$icon_name'" >&2
    exit 1
fi
if ! file "$icon_path" | grep -Fq "Mac OS X icon"; then
    echo "FAIL: copied app icon is not a valid macOS icon: $icon_path" >&2
    exit 1
fi
icon_check_dir="$(mktemp -d "${TMPDIR:-/tmp}/bctask-icon-check.XXXXXXXX")"
trap 'rm -rf "$icon_check_dir"' EXIT
iconutil -c iconset "$icon_path" -o "$icon_check_dir/BCTask.iconset"
if [ ! -s "$icon_check_dir/BCTask.iconset/icon_16x16.png" ] \
    || [ ! -s "$icon_check_dir/BCTask.iconset/icon_512x512@2x.png" ]; then
    echo "FAIL: BCTask.icns must contain readable 16px and 1024px representations" >&2
    exit 1
fi

echo "==> ad-hoc codesign"
codesign --force --sign - "$app_path"

echo "==> verifying bundle metadata"
plutil -lint "$plist_path"
lsuielement="$(plutil -extract LSUIElement raw "$plist_path")"
if [ "$lsuielement" != "true" ]; then
    echo "FAIL: LSUIElement must be true in the bundle, got '$lsuielement'" >&2
    exit 1
fi
bundled_icon="$(plutil -extract CFBundleIconFile raw "$plist_path")"
if [ "$bundled_icon" != "BCTask.icns" ] || [ ! -s "$icon_path" ]; then
    echo "FAIL: signed bundle icon metadata/resource mismatch" >&2
    exit 1
fi
plist_minos="$(plutil -extract LSMinimumSystemVersion raw "$plist_path")"
if [ "$plist_minos" != "$expected_minos" ]; then
    echo "FAIL: LSMinimumSystemVersion must be $expected_minos, got '$plist_minos'" >&2
    exit 1
fi
codesign --verify --strict "$app_path"

echo "==> verifying executable minimum OS (Mach-O)"
if ! command -v otool >/dev/null 2>&1; then
    echo "FAIL: otool not found; cannot verify executable minimum OS" >&2
    exit 1
fi
macho_minos="$(otool -l "$macho_path" | awk '/LC_BUILD_VERSION/{seen=1} seen && $1 == "minos" {print $2; exit}')"
if [ -z "$macho_minos" ]; then
    echo "FAIL: no LC_BUILD_VERSION minos in executable; cannot verify minimum OS" >&2
    exit 1
fi
if [ "$macho_minos" != "$expected_minos" ]; then
    echo "FAIL: executable minimum OS is $macho_minos, expected $expected_minos" >&2
    exit 1
fi

echo "Assembled $app_path ($config); icon=$bundled_icon, LSUIElement=true, plist min OS $plist_minos, Mach-O minos $macho_minos"
