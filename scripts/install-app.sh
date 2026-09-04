#!/bin/sh
# One-command user-local install: build, assemble, and install BCTask.app
# into the user's Applications area — no sudo, no system locations touched.
#
# Usage: scripts/install-app.sh [debug|release]   (default: release)
#
# Calls the canonical scripts/make-app.sh (build + bundle + ad-hoc sign +
# verification), then installs/replaces the bundle at
#   ${BCTASK_INSTALL_DIR:-$HOME/Applications}/BCTask.app
# Only the exact destination bundle path is ever removed/replaced. Paths
# with spaces are safe throughout. Spotlight metadata import and
# LaunchServices registration are requested via stable system commands when
# present; failure of the indexing/registration commands themselves is
# nonfatal.
set -eu

usage() {
    echo "usage: $0 [debug|release]" >&2
    exit 64
}

# Strict argument validation: zero or one argument, exactly debug|release.
case $# in
    0) config="release" ;;
    1) case "$1" in
           debug|release) config="$1" ;;
           *) usage ;;
       esac ;;
    *) usage ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"

# Canonical build + assemble + sign + verify. Its failure aborts this
# script before anything is installed.
sh "$root/scripts/make-app.sh" "$config"

built_app="$root/.build/BCTask.app"
built_executable="$built_app/Contents/MacOS/BCTask"
if [ ! -x "$built_executable" ]; then
    echo "FAIL: assembled bundle has no executable at $built_executable; nothing was installed" >&2
    exit 1
fi
if ! codesign --verify --strict "$built_app" >/dev/null 2>&1; then
    echo "FAIL: assembled bundle failed signature verification; nothing was installed" >&2
    exit 1
fi

install_dir="${BCTASK_INSTALL_DIR:-$HOME/Applications}"

# Refuse to treat nonsensical locations as an install directory.
case "$install_dir" in
    ""|"/") echo "FAIL: refusing nonsensical install directory '$install_dir'" >&2; exit 1 ;;
esac

dest_app="$install_dir/BCTask.app"

mkdir -p "$install_dir" 2>/dev/null || {
    echo "FAIL: cannot create install directory '$install_dir'" >&2
    exit 1
}

if pgrep -x BCTask >/dev/null 2>&1; then
    echo "NOTE: a BCTask process appears to be running."
    echo "      Quit it (menu-bar right-click > Quit) before relaunching; the"
    echo "      running instance keeps serving from the old bundle until then."
fi

# Stage the new bundle fully before replacing the destination, so a failed
# copy never leaves the destination removed. Cleanup targets ONLY the
# staging directory this script created.
stage="$install_dir/.BCTask.app.staging.$$"
cleanup() {
    rm -rf "$stage"
}
trap cleanup EXIT INT TERM

echo "==> installing $built_app -> $dest_app"
cp -R "$built_app" "$stage"
rm -rf "$dest_app"
mv "$stage" "$dest_app"
trap - EXIT INT TERM

# LaunchServices registration so `open -a`/Spotlight recognize the freshly
# replaced bundle immediately; Spotlight metadata import so the app is
# indexed without waiting for the periodic indexer sweep. Both commands are
# stable system tools; an absent command or a command that declines is
# nonfatal.
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$lsregister" ]; then
    "$lsregister" -f "$dest_app" >/dev/null 2>&1 || true
fi
if command -v mdimport >/dev/null 2>&1; then
    mdimport "$dest_app" >/dev/null 2>&1 || true
fi

echo
echo "Installed $dest_app ($config)"
echo
echo "Launch now:"
echo "  open \"$dest_app\"        # or: open -a BCTask"
echo
echo "Notes:"
echo "  - BCTask is menu-bar-only: the main surface appears immediately at"
echo "    launch, no Dock icon, no app-switcher entry."
echo "  - Spotlight discovers the INSTALLED app at this path only; a bundle"
echo "    left in .build is not discoverable."
echo "  - Steering it while it is already running (Spotlight, Finder,"
echo "    \`open -a BCTask\`) surfaces the existing main panel."
echo
echo "Reinstall (rebuild + replace in one step):"
echo "  cd \"$root\" && scripts/install-app.sh          # release"
echo "  cd \"$root\" && scripts/install-app.sh debug    # debug"
echo "  # Custom destination: BCTASK_INSTALL_DIR=\"/path with spaces/BCTask\" scripts/install-app.sh"
