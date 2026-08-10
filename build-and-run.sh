#!/usr/bin/env bash
#
# Build Firnlight (Debug), quit any running instance, and launch the fresh
# build. Intended for a quick edit → rebuild → see-it-running dev loop.
#
# Killing first (rather than just re-launching) is deliberate: FR-1.6 makes a
# second launch merely re-focus the already-running window, so without a quit
# you'd keep looking at the OLD build. We quit gracefully, then hard-kill as a
# fallback.
#
# Requires the full Xcode toolchain (not the Command Line Tools). If xcodebuild
# complains that the active developer dir is a CLT instance, point it at Xcode
# for this run:  DEVELOPER_DIR=/Applications/Xcode<version>.app/Contents/Developer ./build-and-run.sh
set -euo pipefail

cd "$(dirname "$0")"

PROJECT="Firnlight.xcodeproj"
SCHEME="Firnlight"
CONFIG="Debug"
APP_NAME="Firnlight"

# Resolve the built .app path from the build settings (works with whatever
# DerivedData location Xcode uses, so it stays in sync with the IDE).
echo "==> Resolving product path…"
APP_PATH="$(
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -showBuildSettings 2>/dev/null \
  | awk -F' = ' '
      / BUILT_PRODUCTS_DIR / { dir = $2 }
      / FULL_PRODUCT_NAME /   { name = $2 }
      END { if (dir && name) print dir "/" name }
'
)"
if [[ -z "$APP_PATH" ]]; then
  echo "error: could not resolve the product path from build settings" >&2
  exit 1
fi

echo "==> Building $SCHEME ($CONFIG)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: build reported success but no app at: $APP_PATH" >&2
  exit 1
fi

# IconServices caches a rendered icon per bundle path and that cache goes stale:
# the Dock keeps drawing the previous artwork (or the empty placeholder grid) for
# a bundle whose icon has since changed. Rebuilding does not shift it, and
# neither does `lsregister -f -R -trusted`; only deleting the icon store and
# restarting its agent does. That deletion is machine-wide and the Dock restart
# blinks every tile, so it is gated on the icon inputs actually having changed —
# a hash of AppIcon.icon against a stamp kept beside the built product. The stamp
# living in DerivedData is deliberate: wiping DerivedData yields a new bundle
# path, which needs the clear anyway.
ICON_SRC="Firnlight/AppIcon.icon"
ICON_STAMP="$(dirname "$APP_PATH")/.firnlight-icon-hash"
icon_hash() {
  # -print0/sort -z keeps the order stable regardless of directory traversal;
  # hashing the per-file digests folds names and contents into one value.
  find "$ICON_SRC" -type f -print0 | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}'
}
ICON_HASH="$(icon_hash)"
if [[ "$ICON_HASH" != "$(cat "$ICON_STAMP" 2>/dev/null || true)" ]]; then
  echo "==> icon changed — clearing IconServices cache (Dock will restart)"
  CACHE_DIR="$(getconf DARWIN_USER_CACHE_DIR)"
  CACHE_DIR="${CACHE_DIR%/}"
  rm -rf "$CACHE_DIR"/com.apple.iconservicesagent* "$CACHE_DIR"/com.apple.iconservices
  killall iconservicesagent 2>/dev/null || true
  killall Dock 2>/dev/null || true
  printf '%s\n' "$ICON_HASH" >"$ICON_STAMP"
fi

echo "==> Quitting running $APP_NAME (if any)…"
osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
# Fall back to a hard kill for anything the graceful quit didn't catch, then
# wait briefly so the old process releases its window/Photos handles.
pkill -x "$APP_NAME" 2>/dev/null || true
for _ in 1 2 3 4 5; do
  pgrep -x "$APP_NAME" >/dev/null || break
  sleep 0.5
done

echo "==> Launching $APP_PATH"
open "$APP_PATH"
